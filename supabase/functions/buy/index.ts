// Buy a training package or an online course on the website, paid by card or PromptPay QR through Stripe. No sign in.
// order:  checks the package and price in the database (the page never sets the price), then makes the Stripe page
// pp:     PromptPay straight to the gym bank account: returns the gym QR; the buyer taps I have paid (claim) and the desk confirms
// status: after paying, the page asks if the payment went through (package name and start date only)
// When Stripe confirms (stripe-webhook), the database finds or adds the customer and adds the paid package.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// Thai baht payments go to the Thai Stripe account once its key is set (STRIPE_TH_SECRET_KEY), so no currency is lost. Until then, the main account.
const KEY_MAIN = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const KEY_TH = (Deno.env.get("STRIPE_TH_SECRET_KEY") ?? "").trim();
const KEY = KEY_TH || KEY_MAIN;
const PAGE = "https://new.phuketking.com/prices";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const isId = (x: unknown) => typeof x === "string" && /^[0-9a-f-]{36}$/i.test(x);

function backUrl(u: unknown): string {
  try {
    const x = new URL(String(u ?? ""));
    const c = x.searchParams.get("c"), keep = c && /^[a-z0-9-]{1,80}$/.test(c) ? "?c=" + c : "";
    if (x.origin === "https://phuketkinggg.github.io" && x.pathname.startsWith("/pkapp")) return x.origin + x.pathname + keep;
    if (["https://phuketking.com", "https://www.phuketking.com", "https://new.phuketking.com", "https://test.phuketking.com", "https://app.phuketking.com", "https://phuketking-site.pages.dev"].includes(x.origin)) return x.origin + x.pathname + keep;
  } catch { /* fall through */ }
  return PAGE;
}
async function session(o: { id: string; amount: number; what: string; email: string }, back: string, promptpay: boolean) {
  const p = new URLSearchParams();
  p.set("mode", "payment");
  const j0 = back.includes("?") ? "&" : "?";
  p.set("success_url", back + j0 + "paid=1&ref=" + o.id);
  p.set("cancel_url", back + j0 + "paid=0&ref=" + o.id);
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
      const pp = b.pay === "pp";
      if (!pp && !KEY) return json({ error: "Card payment is not set up yet. Choose PromptPay or WhatsApp us." });
      if (!isId(b.package_id) && !isId(b.course_id)) return json({ error: "Choose a package." });
      const { data, error } = await admin.rpc("web_pkg_order", { p: { package_id: isId(b.package_id) ? b.package_id : null, course_id: isId(b.course_id) ? b.course_id : null, name: String(b.name ?? "").slice(0, 80), email: String(b.email ?? "").slice(0, 120),
        phone: String(b.phone ?? "").slice(0, 30), start_on: String(b.start_on ?? "").slice(0, 10), note: String(b.note ?? "").slice(0, 300) } });
      if (error) return json({ error: error.message });
      const o = data as { id: string; amount: number; what: string; email: string };
      if (pp) {
        const { data: acc } = await admin.rpc("web_pkg_promptpay");
        if (!acc?.payload) return json({ error: "PromptPay is not set up yet. Choose card, or WhatsApp us." });
        return json({ id: o.id, amount: o.amount, what: o.what, pp: acc });
      }
      const back = backUrl(b.back);
      let url: string, qr = true;
      try { url = await session(o, back, true); }
      catch (e) {
        if (!/promptpay|payment method/i.test(String((e as Error).message))) throw e;
        url = await session(o, back, false); qr = false;
      }
      return json({ url, qr });
    }
    if (b.mode === "claim") {
      if (!isId(b.ref)) return json({ error: "No order." });
      const { data, error } = await admin.rpc("web_pkg_claim", { p_id: b.ref });
      if (error) return json({ error: error.message });
      return json(data);
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
