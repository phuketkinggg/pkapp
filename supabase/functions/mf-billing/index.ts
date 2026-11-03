// Muay Friend billing (free project bnglnfdgptvnmugntiom). Paid plans through Stripe Checkout, managed in Stripe's billing page.
// From the app (signed in, gym manager): Authorization: Bearer <user token>
//   POST {action:"checkout", g, plan:"gym"|"gym_plus"|"camp"|"master", cycle:"month"|"year", currency?:"thb"|"usd"|"gbp"} -> {url}  (Stripe payment page)
//   POST {action:"portal", g} -> {url}  (change card, switch plan, cancel)
// From Stripe: the webhook (Stripe-Signature header) -> puts the gym on its plan, or back on Free when it ends.
// Setup (once, and after switching to the live key): POST {action:"setup", key:<mf.cfg admin_key>} makes the prices,
//   the launch coupon, the billing page settings and the webhook (its signing secret is kept in mf.cfg).
// Secrets: STRIPE_SECRET_KEY in this project's Edge Function secrets. Never in code or chat.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const SK = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const KEY = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const APP = "https://muayfriend.com/app/";
const SELF = URL_ + "/functions/v1/mf-billing";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, apikey, x-client-info, authorization", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

// monthly prices: baht, dollars and pounds (one Stripe price per plan and cycle, with all three currencies). Yearly = 10 months for 12.
const PLANS: Record<string, { name: string; month: number; usd: number; gbp: number }> = {
  gym: { name: "Muay Friend Gym", month: 1490, usd: 45, gbp: 35 }, gym_plus: { name: "Muay Friend Gym Plus", month: 3290, usd: 99, gbp: 79 },
  camp: { name: "Muay Friend Camp", month: 3990, usd: 119, gbp: 95 }, master: { name: "Muay Friend Master", month: 7990, usd: 239, gbp: 189 },
};
const CURRENCIES = ["thb", "usd", "gbp"];
const LAUNCH = "mf_launch_50"; // 50% off the first 2 months, monthly plans

function form(o: Record<string, unknown>, pre = "", out: string[] = []): string[] {
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || v === null) continue;
    const key = pre ? `${pre}[${k}]` : k;
    if (Array.isArray(v)) v.forEach((x, i) => typeof x === "object" ? form(x as Record<string, unknown>, `${key}[${i}]`, out) : out.push(`${encodeURIComponent(`${key}[${i}]`)}=${encodeURIComponent(String(x))}`));
    else if (typeof v === "object") form(v as Record<string, unknown>, key, out);
    else out.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`);
  }
  return out;
}
async function stripe(method: string, path: string, body?: Record<string, unknown>) {
  if (!SK) throw new Error("no STRIPE_SECRET_KEY");
  const r = await fetch("https://api.stripe.com/v1/" + path, { method, headers: { Authorization: `Bearer ${SK}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: body ? form(body).join("&") : undefined });
  const j = await r.json();
  if (!r.ok) throw new Error("stripe: " + (j?.error?.message ?? r.status));
  return j;
}
const lookup = (plan: string, cycle: string) => `mf_${plan}_${cycle}`;

async function ensurePrices() {
  const keys = Object.keys(PLANS).flatMap((p) => [lookup(p, "month"), lookup(p, "year")]);
  const have = await stripe("GET", "prices?" + form({ lookup_keys: keys, limit: 20, active: true, expand: ["data.currency_options"] }).join("&"));
  const byKey = new Map((have.data ?? []).map((p: Record<string, any>) => [p.lookup_key, p]));
  for (const [plan, p] of Object.entries(PLANS)) {
    for (const cycle of ["month", "year"]) {
      const old = byKey.get(lookup(plan, cycle)) as Record<string, any> | undefined;
      const n = cycle === "year" ? 10 : 1;
      const amt = { thb: p.month * n * 100, usd: p.usd * n * 100, gbp: p.gbp * n * 100 } as Record<string, number>;
      // already right: same amounts in every currency
      if (old && old.currency === "thb" && old.unit_amount === amt.thb
        && ["usd", "gbp"].every((c) => old.currency_options?.[c]?.unit_amount === amt[c])) continue;
      const product = old?.product ?? (await stripe("POST", "products", { name: p.name, metadata: { plan } })).id;
      await stripe("POST", "prices", { product, currency: "thb", unit_amount: amt.thb,
        currency_options: { usd: { unit_amount: amt.usd }, gbp: { unit_amount: amt.gbp } },
        recurring: { interval: cycle }, lookup_key: lookup(plan, cycle), transfer_lookup_key: true, metadata: { plan, cycle } });
      if (old) await stripe("POST", "prices/" + old.id, { active: false });
    }
  }
  try { await stripe("GET", "coupons/" + LAUNCH); } catch (_) {
    await stripe("POST", "coupons", { id: LAUNCH, name: "Launch offer: 50% off 2 months", percent_off: 50, duration: "repeating", duration_in_months: 2 });
  }
}
async function priceId(plan: string, cycle: string) {
  const r = await stripe("GET", "prices?" + form({ lookup_keys: [lookup(plan, cycle)], active: true, limit: 1 }).join("&"));
  if (!r.data?.[0]) { await ensurePrices(); return priceId(plan, cycle); }
  return r.data[0].id as string;
}

async function mail(subject: string, text: string) {
  if (!KEY) return;
  await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: "Muay Friend <hello@muayfriend.com>", to: ["hello@muayfriend.com"], subject, text }) }).catch(() => {});
}

// Stripe-Signature: t=..,v1=..
async function verify(raw: string, sig: string) {
  const secret = (await admin.rpc("mf_billing_cfg", { p_key: "stripe_whsec" })).data as string | null;
  if (!secret) return false;
  const parts = Object.fromEntries(sig.split(",").map((s) => s.split("=") as [string, string]).filter((x) => x.length === 2 && x[0] !== "v1"));
  const v1 = sig.split(",").filter((s) => s.startsWith("v1=")).map((s) => s.slice(3));
  const t = parts.t; if (!t || Math.abs(Date.now() / 1000 - Number(t)) > 600) return false;
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(`${t}.${raw}`)));
  const hex = Array.from(mac).map((b) => b.toString(16).padStart(2, "0")).join("");
  return v1.includes(hex);
}

// a subscription decides the plan
async function applySub(sub: Record<string, any>, slugHint?: string) {
  const slug = slugHint || sub.metadata?.gym || (await admin.rpc("mf_billing_by_sub", { p_sub: sub.id, p_customer: sub.customer })).data;
  if (!slug) return null;
  const price = sub.items?.data?.[0]?.price ?? {};
  const live = ["active", "trialing", "past_due"].includes(sub.status);
  const plan = live ? (price.metadata?.plan ?? "free") : "free";
  const end = sub.items?.data?.[0]?.current_period_end ?? sub.current_period_end;
  const r = await admin.rpc("mf_billing_set", { p_slug: slug, p_plan: plan, p_info: { cycle: price.metadata?.cycle ?? null, status: sub.status, customer: sub.customer, sub: sub.id,
    paid_until: end ? new Date(end * 1000).toISOString() : null } });
  if (r.error) throw new Error("set: " + r.error.message);
  return { slug, plan, status: sub.status };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const raw = await req.text();
  const sig = req.headers.get("stripe-signature");
  try {
    // Stripe webhook
    if (sig) {
      if (!(await verify(raw, sig))) return json({ error: "bad signature" }, 400);
      const ev = JSON.parse(raw); const o = ev.data?.object ?? {};
      if (ev.type === "checkout.session.completed" && o.mode === "subscription" && o.subscription) {
        const sub = await stripe("GET", "subscriptions/" + o.subscription);
        const done = await applySub(sub, o.client_reference_id);
        if (done) await mail(`Paid plan: ${done.slug} is on ${done.plan}`, `${done.slug} started the ${done.plan} plan (${sub.items?.data?.[0]?.price?.metadata?.cycle ?? ""}).\nApp: ${APP}?g=${done.slug}\nEmail: ${o.customer_details?.email ?? ""}\n\nPaid gyms move to their own database: set it up within 4 hours.`);
      } else if (ev.type === "customer.subscription.updated" || ev.type === "customer.subscription.deleted") {
        const done = await applySub(o);
        if (done && ev.type === "customer.subscription.deleted") await mail(`Plan ended: ${done.slug}`, `${done.slug} is back on Free.`);
      }
      return json({ received: true });
    }

    const b = JSON.parse(raw || "{}");
    if (b.action === "setup") {
      const ak = (await admin.rpc("mf_billing_cfg", { p_key: "admin_key" })).data;
      if (!ak || b.key !== ak) return json({ error: "no" }, 403);
      try { await ensurePrices(); } catch (e) { return json({ error: "prices: " + String(e) }, 500); }
      const hooks = await stripe("GET", "webhook_endpoints?limit=100");
      for (const h of hooks.data ?? []) if (h.url === SELF) await stripe("DELETE", "webhook_endpoints/" + h.id);
      const hook = await stripe("POST", "webhook_endpoints", { url: SELF, description: "Muay Friend plans",
        enabled_events: ["checkout.session.completed", "customer.subscription.updated", "customer.subscription.deleted"] });
      await admin.rpc("mf_billing_cfg_set", { p_key: "stripe_whsec", p_value: hook.secret });
      await stripe("POST", "billing_portal/configurations", { business_profile: { headline: "Muay Friend: your plan" }, default_return_url: APP,
        features: { customer_update: { enabled: true, allowed_updates: ["email", "address", "tax_id"] }, invoice_history: { enabled: true },
          payment_method_update: { enabled: true }, subscription_cancel: { enabled: true, mode: "at_period_end" } } }).catch(() => null);
      return json({ ok: true, live: /^(sk|rk)_live_/.test(SK), webhook: hook.id });
    }

    // from the app: the signed-in manager of the gym
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(tok);
    if (!u?.user) return json({ error: "Sign in again, then try once more." }, 401);
    const slug = String(b.g ?? "").toLowerCase();
    const g = (await admin.rpc("mf_billing_gym", { p_slug: slug, p_user: u.user.id })).data as Record<string, any> | null;
    if (!g) return json({ error: "Gym not found." }, 404);
    if (!g.manager) return json({ error: "Only the gym's manager can change the plan." }, 403);
    const back = `${APP}?g=${slug}`;

    if (b.action === "portal") {
      if (!g.customer) return json({ error: "There is no paid plan to manage yet." }, 400);
      const s = await stripe("POST", "billing_portal/sessions", { customer: g.customer, return_url: back });
      return json({ url: s.url });
    }
    if (b.action === "checkout") {
      const plan = String(b.plan), cycle = b.cycle === "year" ? "year" : "month";
      if (!PLANS[plan]) return json({ error: "Choose a plan." }, 400);
      if (g.sub && ["active", "trialing", "past_due"].includes(g.status)) {
        const s = await stripe("POST", "billing_portal/sessions", { customer: g.customer, return_url: back });
        return json({ url: s.url, portal: true });
      }
      let customer = g.customer as string | null;
      if (!customer) {
        customer = (await stripe("POST", "customers", { email: u.user.email, name: g.name, metadata: { gym: slug } })).id;
        await admin.rpc("mf_billing_set", { p_slug: slug, p_plan: g.plan ?? "free", p_info: { customer } });
      }
      const s = await stripe("POST", "checkout/sessions", {
        mode: "subscription", customer, client_reference_id: slug,
        line_items: [{ price: await priceId(plan, cycle), quantity: 1 }],
        discounts: cycle === "month" ? [{ coupon: LAUNCH }] : undefined,
        subscription_data: { metadata: { gym: slug } },
        currency: CURRENCIES.includes(String(b.currency)) ? String(b.currency) : undefined,
        locale: b.lang === "th" ? "th" : "auto",
        success_url: `${back}&paid=1`, cancel_url: back,
      });
      return json({ url: s.url });
    }
    return json({ error: "Unknown action." }, 400);
  } catch (e) {
    console.error(String(e));
    return json({ error: "Something went wrong with the payment page. Please try again." }, 500);
  }
});
