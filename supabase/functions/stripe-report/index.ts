// Lists Stripe charges for the accounts import (read only). Called from the database with the sync token.
// {mode:"fees"} (every hour): looks up Stripe's own fee on each online payment the app has recorded and saves it in THB,
// so Accounts shows sales less Stripe fees. Tries each Stripe account; a payment in another currency is converted at the same rate.
import { createClient } from "npm:@supabase/supabase-js@2";

const KEYS: Record<string, string> = {
  main: (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim(),
  th: (Deno.env.get("STRIPE_TH_SECRET_KEY") ?? "").trim(),
};
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  const body = await req.json().catch(() => ({}));
  if (body.mode === "fees") return json(await fees());
  const key = KEYS[String(body.account ?? "main")];
  if (!key) return json({ error: "No key for that account." });
  const since = Math.floor(new Date(String(body.since ?? "2024-01-01")).getTime() / 1000);
  const out: unknown[] = [];
  let after = "";
  for (let page = 0; page < 60; page++) {
    const q = new URLSearchParams({ limit: "100", "created[gte]": String(since) });
    q.append("expand[]", "data.balance_transaction");
    if (after) q.set("starting_after", after);
    const ep = ["charges", "payment_intents", "balance_transactions", "checkout/sessions"].includes(String(body.ep)) ? String(body.ep) : "charges";
    if (ep !== "charges") { q.delete("expand[]"); if (ep === "payment_intents") q.append("expand[]", "data.latest_charge.balance_transaction"); }
    const r = await fetch(`https://api.stripe.com/v1/${ep}?` + q, { headers: { Authorization: `Bearer ${key}`, "Stripe-Version": "2024-06-20" } });
    const j = await r.json();
    if (!r.ok) return json({ error: j?.error?.message ?? `Stripe said ${r.status}`, got: out.length });
    if (ep !== "charges") {
      for (const x of j.data) {
        const lc = x.latest_charge && typeof x.latest_charge === "object" ? x.latest_charge : null;
        const bt = lc?.balance_transaction && typeof lc.balance_transaction === "object" ? lc.balance_transaction : null;
        out.push({ id: x.id, at: new Date(x.created * 1000).toISOString(), amount: (x.amount ?? x.amount_total ?? 0) / 100, cur: x.currency, status: x.status ?? x.payment_status, desc: x.description ?? x.type ?? "", email: x.receipt_email ?? x.customer_details?.email ?? lc?.billing_details?.email ?? "", name: lc?.billing_details?.name ?? x.customer_details?.name ?? "", refunded: lc ? lc.amount_refunded / 100 : null, fee: bt ? bt.fee / 100 : (x.fee != null ? x.fee / 100 : null), net: bt ? bt.net / 100 : (x.net != null ? x.net / 100 : null), src: x.source ?? null, md: x.metadata ?? {} });
      }
    } else for (const c of j.data) {
      const bt = c.balance_transaction && typeof c.balance_transaction === "object" ? c.balance_transaction : null;
      out.push({
        id: c.id, at: new Date(c.created * 1000).toISOString(), amount: c.amount / 100, cur: c.currency,
        refunded: c.amount_refunded / 100, status: c.status, paid: c.paid, desc: c.description ?? "",
        email: c.billing_details?.email ?? c.receipt_email ?? "", name: c.billing_details?.name ?? "",
        net: bt ? bt.net / 100 : null, fee: bt ? bt.fee / 100 : null, bt_cur: bt?.currency ?? null,
        md: c.metadata ?? {},
      });
    }
    if (!j.has_more || !j.data.length) break;
    after = j.data[j.data.length - 1].id;
  }
  return json({ count: out.length, rows: out });
});

type Todo = { session: string; thb: number };
async function stripeGet(path: string, key: string) {
  const r = await fetch(`https://api.stripe.com/v1/${path}`, { headers: { Authorization: `Bearer ${key}`, "Stripe-Version": "2024-06-20" } });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, j };
}
// the balance transaction of a checkout session, payment intent or charge
async function balanceTx(id: string, key: string) {
  const path = id.startsWith("cs_") ? `checkout/sessions/${id}?expand[]=payment_intent.latest_charge.balance_transaction`
    : id.startsWith("pi_") ? `payment_intents/${id}?expand[]=latest_charge.balance_transaction` : `charges/${id}?expand[]=balance_transaction`;
  const r = await stripeGet(path, key);
  if (!r.ok) return { found: r.status !== 404 && r.j?.error?.code !== "resource_missing" ? null : false, j: r.j };
  const o = r.j;
  const ch = id.startsWith("cs_") ? o.payment_intent?.latest_charge : id.startsWith("pi_") ? o.latest_charge : o;
  const bt = ch && typeof ch === "object" && ch.balance_transaction && typeof ch.balance_transaction === "object" ? ch.balance_transaction : null;
  const gross = id.startsWith("cs_") ? { amount: o.amount_total, cur: o.currency } : { amount: o.amount, cur: o.currency };
  return { found: true, bt, gross };
}
async function fees() {
  const { data, error } = await admin.rpc("stripe_fees_todo", { p_limit: 40 });
  if (error) return { error: error.message };
  const out: Record<string, unknown>[] = [];
  for (const t of (data ?? []) as Todo[]) {
    let row: Record<string, unknown> | null = null, transient = false;
    for (const [acct, key] of Object.entries(KEYS)) {
      if (!key) continue;
      const r = await balanceTx(t.session, key);
      if (r.found === null) { transient = true; continue; }
      if (!r.found) continue;
      const bt = r.bt as { fee: number; amount: number; currency: string } | null;
      if (!bt || !bt.amount) { row = { session: t.session, account: acct, status: "wait" }; break; }
      // the fee as a share of what was paid, applied to the baht the app recorded for it
      const cur = String(r.gross?.cur ?? "thb").toLowerCase();
      const thb = cur === "thb" && r.gross?.amount ? r.gross.amount / 100 : Number(t.thb) || 0;
      const fee = Math.round((bt.fee / bt.amount) * thb * 100) / 100;
      row = { session: t.session, account: acct, fee_thb: fee, gross_thb: thb, currency: cur, status: "ok" };
      break;
    }
    out.push(row ?? { session: t.session, status: transient ? "wait" : "none" });
  }
  if (out.length) { const { error: e2 } = await admin.rpc("stripe_fees_save", { p: out }); if (e2) return { error: e2.message, checked: out.length }; }
  return { checked: out.length, ok: out.filter((x) => x.status === "ok").length };
}
