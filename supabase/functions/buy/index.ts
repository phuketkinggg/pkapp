// Buy a training package on the website, paid by card or PromptPay QR through Stripe. No sign in.
// order:  checks the package and price in the database (the page never sets the price), then makes the Stripe page
// status: after paying, the page asks if the payment went through (package name and start date only)
// When Stripe confirms (stripe-webhook), the database finds or adds the customer and adds the paid package.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const PAGE = "https://new.phuketking.com/prices";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const isId = (x: unknown) => typeof x === "string" && /^[0-9a-f-]{36}$/i.test(x);

function backUrl(u: unknown): string {
  try {
    const x = new URL(String(u ?? ""));
    if (x.origin === "https://phuketkinggg.github.io" && x.pathname.startsWith("/pkapp")) return x.origin + x.pathname;
    if (["https://phuketking.com", "https://www.phuketking.com", "https://new.phuketking.com", "https://test.phuketking.com", "https://app.phuketking.com", "https://phuketking-site.pages.dev"].includes(x.origin)) return x.origin + x.pathname;
  } catch { /* fall through */ }
  return PAGE;
}
async function session(o: { id: string; amount: number; what: string; email: string }, back: string, promptpay: boolean) {
  const p = new URLSearchParams();
  p.set("mode", "payment");
  p.set("success_url", back + "?paid=1&ref=" + o.id);
  p.set("cancel_url", back + "?paid=0&ref=" + o.id);
  p.set("line_items[0][quantity]", "1");
  p.set("line_items[0][price_data][currency]", "thb");
  p.set("line_items[0][price_data][unit_amount]", String(Math.round(o.amount * 100)));
  p.set("line_items[0][price_data][product_data][name]", ("Phuket King: " + o.what).slice(0, 120));
  p.set("payment_method_types[0]", "card");
  if (promptpay) p.set("payment_method_types[1]", "promptpay");
  p.set("customer_email", o.email);
  for (const [k, v] of Object.entries({ kind: "webpkg", id: o.id, amount: String(o.amount) })) { p.set(`metadata[${k}]`, v); p.set(`payment_intent_data[metadata][${k}]`, v); }
  const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/x-www-form-urlencoded", "Stripe-Version": "2024-06-20" }, body: p,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `Stripe said ${r.status}`);
  return j.url as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  try {
    if (b.mode === "order") {
      if (!KEY) return json({ error: "Online payment is not set up yet. WhatsApp us and we will help." });
      if (!isId(b.package_id)) return json({ error: "Choose a package." });
      const { data, error } = await admin.rpc("web_pkg_order", { p: { package_id: b.package_id, name: String(b.name ?? "").slice(0, 80), email: String(b.email ?? "").slice(0, 120),
        phone: String(b.phone ?? "").slice(0, 30), start_on: String(b.start_on ?? "").slice(0, 10), note: String(b.note ?? "").slice(0, 300) } });
      if (error) return json({ error: error.message });
      const o = data as { id: string; amount: number; what: string; email: string };
      const back = backUrl(b.back);
      let url: string, qr = true;
      try { url = await session(o, back, true); }
      catch (e) {
        if (!/promptpay|payment method/i.test(String((e as Error).message))) throw e;
        url = await session(o, back, false); qr = false;
      }
      return json({ url, qr });
    }
    if (b.mode === "status") {
      if (!isId(b.ref)) return json({ error: "No order." });
      const { data } = await admin.rpc("web_pkg_status", { p_id: b.ref });
      return json(data ?? { error: "Order not found." });
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) {
    return json({ error: "Payment could not start: " + (e as Error).message });
  }
});
