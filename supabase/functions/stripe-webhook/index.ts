// Stripe tells us a Checkout page was paid. We check Stripe's signature, then record the money.
import { createClient } from "npm:@supabase/supabase-js@2";

const SECRET = (Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "").trim();
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function hmac(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function same(a: string, b: string) { if (a.length !== b.length) return false; let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i); return x === 0; }

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  if (!SECRET) return new Response("not set up", { status: 500 });
  const raw = await req.text();
  const head = req.headers.get("stripe-signature") ?? "";
  const parts = Object.fromEntries(head.split(",").map((x) => x.split("=")).filter((x) => x.length === 2).map(([k, v]) => [k, v]));
  const t = Number(parts.t ?? 0);
  const v1s = head.split(",").filter((x) => x.startsWith("v1=")).map((x) => x.slice(3));
  if (!t || Math.abs(Date.now() / 1000 - t) > 600) return new Response("old or missing timestamp", { status: 400 });
  const want = await hmac(SECRET, `${t}.${raw}`);
  if (!v1s.some((v) => same(v, want))) return new Response("bad signature", { status: 400 });

  const ev = JSON.parse(raw);
  if (ev.type !== "checkout.session.completed" && ev.type !== "checkout.session.async_payment_succeeded") return new Response("ignored");
  const s = ev.data?.object ?? {};
  if (s.payment_status !== "paid") return new Response("waiting for payment");
  const md = s.metadata ?? {};
  if (!md.kind || !md.id || md.kind === "test") return new Response("no app payment");
  const amount = Math.round(Number(s.amount_total ?? 0) / 100);
  const { data, error } = await admin.rpc("stripe_record", { p_session: s.id, p_kind: md.kind, p_id: md.id, p_amount: amount, p_method: "stripe" });
  if (error) return new Response(`could not record: ${error.message}`, { status: 500 });
  return new Response(JSON.stringify(data ?? { ok: true }), { headers: { "Content-Type": "application/json" } });
});
