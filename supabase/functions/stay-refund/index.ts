// Cancel and refund a stay, money back to the guest's card through Stripe (feature stay_refund).
// POST {stay_id, room, extras:[{id, amount}], pin, reason, cancel}   signed-in desk staff with a manager PIN.
// 1. the database checks the PIN and the amounts (refund_stay with p_dry), as the signed-in person
// 2. Stripe refunds the card: the THB amount is turned into the currency the guest paid in, at the rate they paid
//    (the card fee is not given back). The payment is found on whichever Stripe account took it (main or Thai baht).
// 3. the database records it: money out in the same departments, add-ons stop working, the stay is cancelled if asked.
// Secrets: STRIPE_SECRET_KEY, STRIPE_TH_SECRET_KEY.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEYS = [(Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim(), (Deno.env.get("STRIPE_TH_SECRET_KEY") ?? "").trim()].filter(Boolean);
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const stripe = (key: string, path: string, body?: URLSearchParams) =>
  fetch("https://api.stripe.com/v1/" + path, { method: body ? "POST" : "GET", headers: { Authorization: `Bearer ${key}`, "Stripe-Version": "2024-06-20", ...(body ? { "Content-Type": "application/x-www-form-urlencoded" } : {}) }, body });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({})) as Record<string, unknown>;
  const stayId = String(b.stay_id ?? ""), room = Math.round(Number(b.room) || 0);
  const extras = (Array.isArray(b.extras) ? b.extras : []).slice(0, 30).map((x: Record<string, unknown>) => ({ id: String(x.id ?? ""), amount: Math.round(Number(x.amount) || 0) }));
  if (!/^[0-9a-f-]{36}$/.test(stayId)) return json({ error: "No stay." });
  if (!KEYS.length) return json({ error: "Stripe is not set up." });
  try {
    const { data: feat } = await admin.from("app_settings").select("value").eq("key", "features").maybeSingle();
    if (JSON.parse(feat?.value ?? "{}").stay_refund === false) return json({ error: "Refunds on stays are turned off in Settings, Features." });
  } catch { /* on by default */ }
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const args = { p_stay: stayId, p_room: room, p_extras: extras, p_method: "stripe", p_pin: String(b.pin ?? ""), p_reason: String(b.reason ?? ""), p_cancel: !!b.cancel };
  const { data: chk, error: ce } = await user.rpc("refund_stay", { ...args, p_dry: true });
  if (ce) return json({ error: ce.message });
  const total = Number((chk as { total?: number })?.total || 0);
  let note = "";
  if (total > 0) {
    // the online payment for this stay (the room, or an add-on paid with the booking)
    const ids = extras.map((x) => x.id).filter((x) => /^[0-9a-f-]{36}$/.test(x));
    const { data: pays } = await admin.from("payments").select("stripe_session, amount_thb, stay_id, purchase_id").not("stripe_session", "is", null).eq("voided", false).gt("amount_thb", 0)
      .or([`stay_id.eq.${stayId}`].concat(ids.length ? [`purchase_id.in.(${ids.join(",")})`] : []).join(","));
    const sess = [...new Set((pays ?? []).map((p) => p.stripe_session as string))];
    if (!sess.length) return json({ error: "This stay was not paid online, so there is no card to refund. Choose cash or bank transfer." });
    if (sess.length > 1) return json({ error: "This stay was paid in more than one online payment. Refund each one in Stripe, then record it here with Bank transfer." });
    let key = "", s: Record<string, unknown> | null = null;
    for (const k of KEYS) { const r = await stripe(k, `checkout/sessions/${sess[0]}?expand[]=payment_intent.latest_charge`); if (r.ok) { key = k; s = await r.json(); break; } }
    if (!s) return json({ error: "That payment was not found in Stripe." });
    const pi = s.payment_intent as Record<string, unknown> | null, md = (s.metadata ?? {}) as Record<string, string>;
    if (!pi?.id || pi.status !== "succeeded") return json({ error: "That Stripe payment did not go through, so there is nothing to refund." });
    // the rate they paid at: what was charged (without the card fee) for the THB amount
    const thb = Number(md.amount) || 0, fee = Number(md.fee) || 0, cur = String(s.currency ?? "thb");
    const charged = Number(s.amount_total) || 0, feeMinor = thb + fee > 0 ? Math.round(charged * fee / (thb + fee)) : 0;
    const perThb = thb > 0 ? (charged - feeMinor) / thb : 100;
    const ch = (pi.latest_charge ?? {}) as Record<string, unknown>, left = Number(ch.amount ?? charged) - Number(ch.amount_refunded ?? 0);
    let minor = Math.round(total * perThb);
    if (left <= 0) return json({ error: "This payment was already refunded in full in Stripe." });
    minor = Math.min(minor, left);
    const p = new URLSearchParams();
    p.set("payment_intent", String(pi.id)); p.set("amount", String(minor)); p.set("reason", "requested_by_customer");
    p.set("metadata[stay_id]", stayId); p.set("metadata[thb]", String(total));
    const r = await stripe(key, "refunds", p), j = await r.json();
    if (!r.ok) return json({ error: "Stripe: " + (j?.error?.message ?? `said ${r.status}`) });
    note = `Stripe refund ${j.id}` + (cur !== "thb" ? `, ${cur.toUpperCase()} ${(minor / 100).toFixed(2)}` : "");
  }
  const { data, error } = await user.rpc("refund_stay", { ...args, p_dry: false, p_note: note || null });
  if (error) return json({ error: (note ? "The card was refunded (" + note + ") but the app could not record it: " + error.message + ". Record it by hand with Bank transfer." : error.message) });
  return json({ ok: true, refunded: (data as { refunded?: number })?.refunded ?? total, stripe: note || null });
});
