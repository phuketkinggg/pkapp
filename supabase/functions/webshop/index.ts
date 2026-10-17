// The website shop page talks to this. No sign in. Products come straight from the app shop (only ones marked "show on the website").
// list:   products, prices, photos, sold out or not (no costs, no stock counts)
// order:  place an order to collect at the gym reception, paid by card now (Stripe) or when collecting
// status: after paying, the page asks if the payment went through
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const PAGE = "https://phuketkinggg.github.io/pkapp/pk/shop.html";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const isId = (x: unknown) => typeof x === "string" && /^[0-9a-f-]{36}$/i.test(x);

function backUrl(u: unknown): string {
  try {
    const x = new URL(String(u ?? ""));
    if (x.origin === "https://phuketkinggg.github.io" && x.pathname.startsWith("/pkapp")) return x.origin + x.pathname;
    if (["https://app.phuketking.com", "https://phuketking.com", "https://www.phuketking.com", "https://new.phuketking.com", "https://test.phuketking.com"].includes(x.origin)) return x.origin + x.pathname;
  } catch { /* fall through */ }
  return PAGE;
}
async function stripeSession(lines: { name: string; qty: number; price: number }[], amount: number, orderId: string, email: string, back: string) {
  const p = new URLSearchParams();
  p.set("mode", "payment");
  p.set("success_url", back + "?paid=1&ref=" + orderId);
  p.set("cancel_url", back + "?paid=0&ref=" + orderId);
  p.set("expires_at", String(Math.floor(Date.now() / 1000) + 30 * 60 + 30));
  lines.forEach((l, i) => {
    p.set(`line_items[${i}][quantity]`, String(l.qty));
    p.set(`line_items[${i}][price_data][currency]`, "thb");
    p.set(`line_items[${i}][price_data][unit_amount]`, String(Math.round(l.price * 100)));
    p.set(`line_items[${i}][price_data][product_data][name]`, l.name.slice(0, 120));
  });
  p.set("payment_method_types[0]", "card");
  p.set("customer_email", email);
  for (const [k, v] of Object.entries({ kind: "order", id: orderId, amount: String(amount) })) { p.set(`metadata[${k}]`, v); p.set(`payment_intent_data[metadata][${k}]`, v); }
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
  const body = await req.json().catch(() => ({}));
  try {
    if (body.mode === "list") {
      const { data, error } = await admin.rpc("web_shop_list");
      if (error) throw error;
      return json(data);
    }
    if (body.mode === "order") {
      await admin.rpc("web_shop_cleanup");
      const items = Array.isArray(body.items) ? body.items.filter((i: { product_id?: unknown }) => isId(i?.product_id)).slice(0, 30) : [];
      const pay = body.pay === "card" ? "card" : "pickup";
      const { data, error } = await admin.rpc("web_shop_order", { p: { name: String(body.name ?? "").slice(0, 80), email: String(body.email ?? "").slice(0, 120), phone: String(body.phone ?? "").slice(0, 30),
        note: String(body.note ?? "").slice(0, 250), pay, items: items.map((i: { product_id: string; qty?: number }) => ({ product_id: i.product_id, qty: Number(i.qty) || 1 })) } });
      if (error) return json({ error: error.message });
      const o = data as { order_id: string; number: number; total: number; email: string };
      if (pay !== "card") return json({ number: o.number, total: o.total, pay });
      if (!KEY) { await admin.rpc("web_shop_cancel", { p_id: o.order_id }); return json({ error: "Card payments are not set up yet. Choose pay when you collect." }); }
      await admin.from("shop_orders").update({ web_card: true }).eq("id", o.order_id);
      const { data: lines } = await admin.from("shop_order_items").select("name,qty,price_thb").eq("order_id", o.order_id);
      try {
        const url = await stripeSession((lines ?? []).map((l) => ({ name: l.name, qty: l.qty, price: l.price_thb })), o.total, o.order_id, o.email, backUrl(body.back));
        return json({ url, number: o.number });
      } catch (e) {
        await admin.rpc("web_shop_cancel", { p_id: o.order_id });
        return json({ error: "Card payment could not start: " + (e as Error).message });
      }
    }
    if (body.mode === "status") {
      if (!isId(body.ref)) return json({ error: "No order." });
      const { data } = await admin.rpc("web_shop_status", { p_id: body.ref });
      return json(data ?? { error: "Order not found." });
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
