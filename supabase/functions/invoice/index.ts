// The customer's invoice page (invoice.html) talks to this. No sign in: the long token in the link is the key.
// POST {mode:'view', t}            the invoice, the template and the PromptPay QR details
// POST {mode:'pay', t, back}       a Stripe card payment page for what is still owed
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
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
    const amount = Number(inv.total);
    if (!(amount >= 20)) return json({ error: "Card payments need at least 20 THB." });
    const tpl = data.template ?? {}, prefix = tpl.prefix || "INV-", pad = Number(tpl.pad) || 4;
    const no = prefix + String(inv.number).padStart(pad, "0");
    const biz = (tpl.biz?.[inv.business]?.name) || (inv.business === "Pangea Resort" ? "Pangea Resort" : "Phuket King Muay Thai");
    const where = back(b.back);
    const p = new URLSearchParams();
    p.set("mode", "payment");
    p.set("success_url", `${where}?t=${t}&paid=1`);
    p.set("cancel_url", `${where}?t=${t}`);
    p.set("line_items[0][quantity]", "1");
    p.set("line_items[0][price_data][currency]", "thb");
    p.set("line_items[0][price_data][unit_amount]", String(Math.round(amount * 100)));
    p.set("line_items[0][price_data][product_data][name]", `${biz}, invoice ${no}`.slice(0, 120));
    p.set("payment_method_types[0]", "card");
    if (inv.to_email) p.set("customer_email", inv.to_email);
    for (const [k, v] of Object.entries({ kind: "invoice", id: inv.id, amount: String(amount) })) { p.set(`metadata[${k}]`, v); p.set(`payment_intent_data[metadata][${k}]`, v); }
    const r = await fetch("https://api.stripe.com/v1/checkout/sessions", { method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/x-www-form-urlencoded", "Stripe-Version": "2024-06-20" }, body: p });
    const j = await r.json();
    if (!r.ok) return json({ error: "Stripe: " + (j?.error?.message ?? r.status) });
    return json({ url: j.url });
  }
  return json({ error: "Unknown request." }, 400);
});
