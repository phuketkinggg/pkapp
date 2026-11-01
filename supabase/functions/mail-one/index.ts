// One email to one person, written in the app by the owner or an admin (Contacts, a contact's page, Send an email).
// POST {id}  signed-in manager: sends that saved draft (Resend). Replies go to hello@phuketking.com.
// The sending address is a setting (app_settings key email_sender: {"email":"hello@yourdomain.com","name":"Your Business","reply_to":"..."}).
// Sending from your main domain lands in the inbox far more often than a new subdomain. If Resend has not verified
// that domain yet, the email goes from the default address instead, so nothing is lost.
// POST {mode:"queue"} with x-sync-token (cron every 10 minutes): sends queued outreach emails that are due, a few at a time.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

// a personal email: plain paragraphs, links made clickable, no banner
function toHtml(t: string) {
  const link = (s: string) => esc(s).replace(/\b(https:\/\/[^\s<]+|www\.[a-z0-9.-]+\.[a-z]{2,}[^\s<]*)/gi, (u) => {
    const clean = u.replace(/[.,)]+$/, ""), rest = u.slice(clean.length), href = /^https:/i.test(clean) ? clean : "https://" + clean;
    return `<a href="${href.replace(/&amp;/g, "&").replace(/"/g, "%22")}" style="color:#B8001A">${clean}</a>${rest}`;
  });
  const paras = String(t).replace(/\r/g, "").split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean)
    .map((p) => `<p style="margin:0 0 14px">${link(p).replace(/\n/g, "<br>")}</p>`).join("");
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>` +
    `<body style="margin:0;padding:16px;font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.55;color:#171B23">${paras}</body></html>`;
}

const DEF_FROM = "hello@app.phuketking.com", DEF_REPLY = "hello@phuketking.com";
const okMail = (s: unknown) => /^[^\s@<>",]+@[^\s@<>",]+\.[a-z]{2,}$/i.test(String(s ?? "").trim());
let SENDER: { email: string; reply_to: string; biz: string; at: number } | null = null;
async function sender() {
  if (SENDER && Date.now() - SENDER.at < 60000) return SENDER;
  const { data } = await admin.from("app_settings").select("key,value").in("key", ["email_sender", "acc_names"]);
  const get = (k: string) => { try { const v = (data ?? []).find((r: { key: string }) => r.key === k)?.value; return typeof v === "string" ? JSON.parse(v) : (v ?? {}); } catch { return {}; } };
  const w = get("email_sender"), n = get("acc_names");
  const biz = String(w.name || n.main || "Our team").replace(/[<>"\r\n,]/g, "").trim() || "Our team";
  SENDER = { email: okMail(w.email) ? String(w.email).trim() : DEF_FROM, reply_to: okMail(w.reply_to) ? String(w.reply_to).trim() : DEF_REPLY, biz, at: Date.now() };
  return SENDER;
}

async function post(msg: Record<string, unknown>) {
  const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" }, body: JSON.stringify(msg) });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, rid: String((j as { id?: string }).id ?? ""), err: r.ok ? "" : String((j as { message?: string }).message ?? ("Error " + r.status)) };
}

async function send1(e: { id: string; to: string; subject: string; body: string; from_name?: string }, bulk: boolean) {
  const s = await sender();
  const who = String(e.from_name || "").replace(/[<>"\r\n,]/g, "").trim();
  const name = who ? who + ", " + s.biz : s.biz;
  let ok = false, rid = "", err = "", note = "";
  try {
    const msg: Record<string, unknown> = { from: `${name} <${s.email}>`, to: [e.to], reply_to: s.reply_to, subject: e.subject, html: toHtml(e.body), text: e.body };
    if (bulk) msg.headers = { "List-Unsubscribe": `<mailto:${s.reply_to}?subject=stop>` };
    let r = await post(msg);
    // the chosen domain is not verified in Resend yet: send from the default address so the email still goes
    if (!r.ok && s.email !== DEF_FROM && /domain|verif|authori/i.test(r.err)) { note = `Sent from ${DEF_FROM}: ${r.err}`.slice(0, 300); msg.from = `${name} <${DEF_FROM}>`; r = await post(msg); }
    ok = r.ok; rid = r.rid; err = r.err;
  } catch (x) { err = String(x).slice(0, 200); }
  await admin.from("sent_emails").update(ok ? { status: "sent", sent_at: new Date().toISOString(), resend_id: rid, error: note || null } : { status: "failed", error: err.slice(0, 300) }).eq("id", e.id);
  return { ok, err };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (!RESEND) return json({ error: "Email sending is not set up yet. Add RESEND_API_KEY in Supabase." });
  const b = await req.json().catch(() => ({}));
  if (b.mode === "queue") {
    const { data: tok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
    if (tok !== true) return json({ error: "Not allowed." }, 401);
    const { data: due, error: qe } = await admin.rpc("email_queue_take", { p_limit: 6 });
    if (qe) return json({ error: qe.message });
    let sent = 0, failed = 0;
    for (const e of (due as { id: string; to: string; subject: string; body: string; from_name?: string }[]) ?? []) {
      const r = await send1(e, true); if (r.ok) sent++; else failed++;
      await new Promise((ok) => setTimeout(ok, 1500));
    }
    return json({ sent, failed });
  }
  if (!/^[0-9a-f-]{36}$/i.test(String(b.id ?? ""))) return json({ error: "Save the email first." });
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const { data: m, error } = await user.rpc("email_one_claim", { p_id: b.id });
  if (error) return json({ error: error.message });
  const r = await send1(m as { id: string; to: string; subject: string; body: string; from_name?: string }, false);
  return r.ok ? json({ ok: true }) : json({ error: "Not sent: " + r.err });
});
