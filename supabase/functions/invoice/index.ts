// The customer's invoice page (invoice.html) talks to this. No sign in: the long token in the link is the key.
// POST {mode:'view', t}            the invoice, the template and the PromptPay QR details
// POST {mode:'pay', t, back}       a Stripe card payment page for what is to pay now (the deposit, or the rest)
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// Thai baht payments go to the Thai Stripe account once its key is set (STRIPE_TH_SECRET_KEY), so no currency is lost. Until then, the main account.
const KEY_MAIN = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const KEY_TH = (Deno.env.get("STRIPE_TH_SECRET_KEY") ?? "").trim();
const KEY = KEY_TH || KEY_MAIN;
// Feature stays_main_stripe (on unless the business turns it off in Settings, Features): stay and room payments by card go to the main
// Stripe account (the old account, settles in pounds), not the Thai baht one. PromptPay QR can only use the Thai account.
async function staysToMain(): Promise<boolean> {
  try { const { data } = await admin.from("app_settings").select("value").eq("key", "features").maybeSingle(); return JSON.parse(data?.value ?? "{}").stays_main_stripe !== false; }
  catch { return true; }
}
// an invoice from the stay business (Accounts, Businesses: the stay name)
async function isStayBiz(name: string): Promise<boolean> {
  try { const { data } = await admin.from("app_settings").select("value").eq("key", "acc_names").maybeSingle(); const n = JSON.parse(data?.value ?? "{}"); return !!name && name === (n.stay || "Stay"); }
  catch { return false; }
}

// customers paying by card pay the card fee (Settings, Card fee and tax, normally 3% + 10 THB, the 10 THB only under 2,000 THB), shown as its own line on the Stripe page.
// No fee above the online limit (online_free_over), and none on stays when stay_card_fee is false.
type CardRule = { pct: number; fixed: number; under: number; over: number; stays: boolean };
// the fee is a percent plus a fixed amount; above "under" baht the fixed part is not charged (we cover it)
async function cardRule(): Promise<CardRule> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "pay_extras").maybeSingle();
  let j: Record<string, unknown> = {}; try { j = JSON.parse(data?.value ?? "{}"); } catch { /* defaults */ }
  const n = (v: unknown, d: number, max: number) => { const x = Number(v); return v != null && Number.isFinite(x) && x >= 0 && x <= max ? x : d; };
  // over: no card fee online above this amount (0: always a fee). stays: false means never a card fee on a stay
  return { pct: n(j.card_pct, 3, 20), fixed: n(j.card_fixed, 10, 1000), under: n(j.card_fixed_under, 2000, 10000000), over: n(j.online_free_over, 0, 10000000), stays: j.stay_card_fee !== false };
}
const cardFee = (amount: number, r: CardRule, stay = false) => amount > 0 && !(stay && !r.stays) && !(r.over > 0 && amount > r.over) ? Math.round(amount * r.pct / 100) + (r.fixed > 0 && amount < r.under ? r.fixed : 0) : 0;
const cardLabel = (amount: number, r: CardRule) => `Card fee (${r.pct}%${r.fixed > 0 && amount < r.under ? ` + ${r.fixed} THB` : ""})`;
const PAGE = "https://app.phuketking.com/invoice.html";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

function back(u: unknown) {
  try { const x = new URL(String(u ?? "")); if (["https://app.phuketking.com", "https://phuketkinggg.github.io", "https://muayfriend.com"].includes(x.origin)) return x.origin + x.pathname; } catch { /* default */ }
  return PAGE;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  const t = String(b.t ?? "");
  if (!/^[0-9a-f]{16,64}$/.test(t)) return json({ error: "This invoice link is not valid." }, 404);
  const { data, error } = await admin.rpc("invoice_public", { p_token: t });
  if (error) return json({ error: error.message }, 500);
  if (!data) return json({ error: "This invoice was not found. It may have been cancelled." }, 404);
  if (b.mode === "view") return json(data);
  if (b.mode === "pay") {
    const inv = data.invoice;
    if (inv.status === "paid") return json({ error: "This invoice is already paid." });
    if (!inv.pay_card) return json({ error: "Card payment is not offered on this invoice." });
    if (!KEY) return json({ error: "Card payments are not set up yet." });
    const amount = Number(inv.due_now ?? inv.total), part = inv.status === "unpaid" && Number(inv.deposit) > 0 ? "deposit" : inv.status === "deposit_paid" ? "balance" : "";
    if (!(amount > 0)) return json({ error: "Nothing is owed on this invoice." });
    if (!(amount >= 20)) return json({ error: "Card payments need at least 20 THB." });
    const tpl = data.template ?? {}, prefix = tpl.prefix || "INV-", pad = Number(tpl.pad) || 4;
    const no = prefix + String(inv.number).padStart(pad, "0");
    const biz = (tpl.biz?.[inv.business]?.name) || inv.business || "Invoice";
    const where = back(b.back);
    const p = new URLSearchParams();
    p.set("mode", "payment");
    p.set("success_url", `${where}?t=${t}&paid=1${part ? "&part=" + part : ""}`);
    p.set("cancel_url", `${where}?t=${t}`);
    p.set("line_items[0][quantity]", "1");
    p.set("line_items[0][price_data][currency]", "thb");
    p.set("line_items[0][price_data][unit_amount]", String(Math.round(amount * 100)));
    p.set("line_items[0][price_data][product_data][name]", `${biz}, invoice ${no}${part ? " " + part : ""}`.slice(0, 120));
    const rule = await cardRule(), fee = cardFee(amount, rule);
    if (fee > 0) { p.set("line_items[1][quantity]", "1"); p.set("line_items[1][price_data][currency]", "thb"); p.set("line_items[1][price_data][unit_amount]", String(fee * 100)); p.set("line_items[1][price_data][product_data][name]", cardLabel(amount, rule)); }
    p.set("payment_method_types[0]", "card");
    if (inv.to_email) p.set("customer_email", inv.to_email);
    for (const [k, v] of Object.entries({ kind: "invoice", id: inv.id, amount: String(amount), fee: String(fee) })) { p.set(`metadata[${k}]`, v); p.set(`payment_intent_data[metadata][${k}]`, v); }
    const key = KEY_MAIN && await isStayBiz(String(inv.business ?? "")) && await staysToMain() ? KEY_MAIN : KEY;
    const r = await fetch("https://api.stripe.com/v1/checkout/sessions", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded", "Stripe-Version": "2024-06-20" }, body: p });
    const j = await r.json();
    if (!r.ok) return json({ error: "Stripe: " + (j?.error?.message ?? r.status) });
    return json({ url: j.url });
  }
  return json({ error: "Unknown request." }, 400);
});
