// Makes a Stripe Checkout page for something a customer owes. The database works out the amount; the phone never sets it.
import { createClient } from "npm:@supabase/supabase-js@2";

// Thai baht payments go to the Thai Stripe account once its key is set (STRIPE_TH_SECRET_KEY), so no currency is lost. Until then, the main account.
const KEY_MAIN = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const KEY_TH = (Deno.env.get("STRIPE_TH_SECRET_KEY") ?? "").trim();
const KEY = KEY_TH || KEY_MAIN;

// customers paying by card always pay the card fee (Settings, Card fee and tax, normally 3%), shown as its own line on the Stripe page
async function cardPct(): Promise<number> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "pay_extras").maybeSingle();
  try { const v = Number(JSON.parse(data?.value ?? "{}").card_pct); return Number.isFinite(v) && v >= 0 && v <= 20 ? v : 3; } catch { return 3; }
}
const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const APP = "https://phuketkinggg.github.io/pkapp/";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

function backUrl(u: unknown): string {
  try {
    const x = new URL(String(u ?? ""));
    if (x.origin === "https://phuketkinggg.github.io" && x.pathname.startsWith("/pkapp")) return x.origin + x.pathname;
    if (x.origin === "https://app.phuketking.com") return x.origin + x.pathname;
  } catch { /* fall through */ }
  return APP;
}

async function session(amount: number, what: string, meta: Record<string, string>, email: string | null, back: string, promptpay: boolean, fee = 0, pct = 0) {
  const p = new URLSearchParams();
  p.set("mode", "payment");
  p.set("success_url", back + "?paid=1");
  p.set("cancel_url", back + "?paid=0");
  p.set("line_items[0][quantity]", "1");
  p.set("line_items[0][price_data][currency]", "thb");
  p.set("line_items[0][price_data][unit_amount]", String(Math.round(amount * 100)));
  p.set("line_items[0][price_data][product_data][name]", what.slice(0, 120));
  if (fee > 0) { p.set("line_items[1][quantity]", "1"); p.set("line_items[1][price_data][currency]", "thb"); p.set("line_items[1][price_data][unit_amount]", String(Math.round(fee * 100))); p.set("line_items[1][price_data][product_data][name]", `Card fee (${pct}%)`); }
  p.set("payment_method_types[0]", "card");
  if (promptpay && !(fee > 0)) p.set("payment_method_types[1]", "promptpay");
  if (email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) p.set("customer_email", email);
  for (const [k, v] of Object.entries(meta)) { p.set(`metadata[${k}]`, v); p.set(`payment_intent_data[metadata][${k}]`, v); }
  const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/x-www-form-urlencoded", "Stripe-Version": "2024-06-20" },
    body: p,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `Stripe said ${r.status}`);
  return j;
}
async function make(amount: number, what: string, meta: Record<string, string>, email: string | null, back: string, fee = 0, pct = 0) {
  if (fee > 0) return { s: await session(amount, what, meta, email, back, false, fee, pct), promptpay: false };
  try { return { s: await session(amount, what, meta, email, back, true), promptpay: true }; }
  catch (e) {
    if (!/promptpay|payment method/i.test(String((e as Error).message))) throw e;
    return { s: await session(amount, what, meta, email, back, false), promptpay: false };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!KEY) return json({ error: "Stripe is not set up yet (STRIPE_SECRET_KEY is missing)." });
  const body = await req.json().catch(() => ({}));
  try {
    // a quick check from the database job: can we make a page at all
    if (body.mode === "ping") {
      const { data } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
      if (data !== true) return json({ error: "Not allowed." }, 401);
      const m = await make(20, "Test, not charged", { kind: "test", id: "test", amount: "20" }, null, APP);
      return json({ ok: true, promptpay: m.promptpay, livemode: m.s.livemode });
    }
    const auth = req.headers.get("authorization") ?? "";
    const user = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: q, error } = await user.rpc("stripe_quote", { p_kind: String(body.kind ?? ""), p_id: body.id ? String(body.id) : null });
    if (error) return json({ error: error.message });
    const amount = Number(q.amount);
    if (!(amount >= 20)) return json({ error: "Card payments need at least 20 THB." });
    // a customer paying for themselves (member app), or anyone on the kiosk, pays the card fee; staff making a link choose on their own form
    const { data: who } = await user.auth.getUser();
    const { data: st } = who?.user ? await admin.from("staff").select("id").eq("user_id", who.user.id).eq("active", true).maybeSingle() : { data: null };
    const pct = (!st || body.kiosk === true) ? await cardPct() : 0, fee = Math.round(amount * pct / 100);
    const m = await make(amount, String(q.what ?? "Phuket King"), { kind: String(body.kind), id: String(body.kind === "customer" ? q.customer_id : body.id), amount: String(amount), fee: String(fee) }, q.email ?? null, backUrl(body.back), fee, pct);
    return json({ url: m.s.url, amount, fee, total: amount + fee, promptpay: m.promptpay });
  } catch (e) {
    return json({ error: `Stripe: ${(e as Error).message}` });
  }
});
