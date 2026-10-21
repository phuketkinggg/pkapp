// Stripe tells us a Checkout page was paid. We check Stripe's signature, then record the money.
import { createClient } from "npm:@supabase/supabase-js@2";

// two Stripe accounts: the main one, and the Thai baht one (each has its own signing secret)
const SECRETS = [Deno.env.get("STRIPE_WEBHOOK_SECRET"), Deno.env.get("STRIPE_TH_WEBHOOK_SECRET")].map((x) => (x ?? "").trim()).filter(Boolean);
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function hmac(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function same(a: string, b: string) { if (a.length !== b.length) return false; let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i); return x === 0; }

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  if (!SECRETS.length) return new Response("not set up", { status: 500 });
  const raw = await req.text();
  const head = req.headers.get("stripe-signature") ?? "";
  const parts = Object.fromEntries(head.split(",").map((x) => x.split("=")).filter((x) => x.length === 2).map(([k, v]) => [k, v]));
  const t = Number(parts.t ?? 0);
  const v1s = head.split(",").filter((x) => x.startsWith("v1=")).map((x) => x.slice(3));
  if (!t || Math.abs(Date.now() / 1000 - t) > 600) return new Response("old or missing timestamp", { status: 400 });
  let ok = false;
  for (const sec of SECRETS) { const want = await hmac(sec, `${t}.${raw}`); if (v1s.some((v) => same(v, want))) { ok = true; break; } }
  if (!ok) return new Response("bad signature", { status: 400 });

  const ev = JSON.parse(raw);
  if (ev.type !== "checkout.session.completed" && ev.type !== "checkout.session.async_payment_succeeded") return new Response("ignored");
  const s = ev.data?.object ?? {};
  if (s.payment_status !== "paid") return new Response("waiting for payment");
  const md = s.metadata ?? {};
  if (!md.kind || !md.id || md.kind === "test") return new Response("no app payment");
  // paid in another currency (US dollars, pounds, euros): the app keeps the THB value we priced it at
  const cur = String(s.currency ?? "thb").toLowerCase();
  const amount = cur === "thb" ? Math.round(Number(s.amount_total ?? 0) / 100) : Math.round(Number(md.amount ?? 0));
  if (!(amount > 0)) return new Response("no amount");
  const { data, error } = await admin.rpc("stripe_record", { p_session: s.id, p_kind: md.kind, p_id: md.id, p_amount: amount, p_method: "stripe" });
  if (error) return new Response(`could not record: ${error.message}`, { status: 500 });
  if (cur !== "thb") {
    const paid = `${cur.toUpperCase()} ${(Number(s.amount_total ?? 0) / 100).toFixed(2)}`;
    const { data: ps } = await admin.from("payments").select("id, note").like("stripe_session", `${s.id}%`);
    for (const p of ps ?? []) await admin.from("payments").update({ note: `${p.note ?? "Paid online"} (paid ${paid})` }).eq("id", p.id);
  }
  return new Response(JSON.stringify(data ?? { ok: true }), { headers: { "Content-Type": "application/json" } });
});
