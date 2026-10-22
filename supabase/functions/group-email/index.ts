// Email steps from action groups (Coaching). A coach writes the subject and message and schedules the step; this sends what is due.
// POST {mode:'auto'}                              the timer (x-sync-token): sends every email step that is due now
// POST {mode:'test', subject, text, url, button}  a coach or manager sends a copy of one email to their own address
import { createClient } from "npm:@supabase/supabase-js@2";

const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const APP = "https://app.phuketking.com/";
const UNSUB = URL_ + "/functions/v1/newsletter";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const first = (n: unknown) => { const f = String(n ?? "").trim().split(/\s+/)[0]; return f && f.length < 30 ? f : "there"; };
const G = "#1a3325", C = "#f5f0e8", GOLD = "#c9a84c", INK = "#22201c", MUT = "#6b665c";

// the same simple format as the blog and newsletters: blank line = paragraph, ## heading, - list, **bold**, *italic*, [text](https://link)
function inl(t: string) {
  return esc(t).replace(/\[([^\]]+)\]\((https:\/\/[^)\s]+)\)/g, (_m, a, u) => `<a href="${u.replace(/&amp;/g, "&").replace(/"/g, "%22")}" style="color:${G};font-weight:bold">${a}</a>`)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/\*([^*\n]+)\*/g, "<em>$1</em>").replace(/\n/g, "<br>");
}
function toHtml(md: string) {
  return String(md || "").replace(/\r/g, "").split(/\n\s*\n/).map((b) => {
    b = b.trim(); if (!b) return "";
    const m = b.match(/^!\[([^\]]*)\]\((https:\/\/[^)\s]+)\)$/);
    if (m) return `<p style="margin:0 0 18px"><img src="${esc(m[2])}" alt="${esc(m[1])}" style="max-width:100%;height:auto;border-radius:8px;display:block"></p>`;
    if (/^##? /.test(b)) return `<h2 style="font-size:20px;margin:22px 0 10px;color:${G}">${inl(b.replace(/^##? /, ""))}</h2>`;
    const lines = b.split("\n");
    if (lines.every((l) => /^[-*] /.test(l))) return `<ul style="margin:0 0 18px;padding-left:22px">${lines.map((l) => `<li style="margin:0 0 6px">${inl(l.slice(2))}</li>`).join("")}</ul>`;
    if (lines.every((l) => /^\d+[.)] /.test(l))) return `<ol style="margin:0 0 18px;padding-left:22px">${lines.map((l) => `<li style="margin:0 0 6px">${inl(l.replace(/^\d+[.)] /, ""))}</li>`).join("")}</ol>`;
    return `<p style="margin:0 0 18px">${inl(b)}</p>`;
  }).join("");
}
function toText(md: string) {
  return String(md || "").replace(/!\[([^\]]*)\]\(([^)]+)\)/g, "").replace(/\[([^\]]+)\]\(([^)]+)\)/g, "$1 ($2)").replace(/\*\*([^*]+)\*\*/g, "$1").replace(/^#+ /gm, "").trim();
}
const fill = (s: string, name: string) => String(s || "").replace(/\{\{?\s*(first|name|first name)\s*\}?\}/gi, first(name));

type Mail = { name: string; subject: string; text: string; url?: string | null; button?: string | null; token?: string | null; group?: string | null };
function build(m: Mail) {
  const subject = fill(m.subject, m.name), body = fill(m.text, m.name);
  const link = m.url || APP, label = m.button || (m.url ? "Open" : "Open my app");
  const unsub = m.token ? `${UNSUB}?u=${m.token}` : "";
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:${C};font-family:Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C}"><tr><td align="center" style="padding:20px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px">
  <tr><td style="background:${G};border-radius:12px 12px 0 0;padding:22px 24px;color:#ffffff">
    <div style="color:${GOLD};font-size:13px;letter-spacing:2px;text-transform:uppercase;font-weight:bold">Phuket King Muay Thai</div>
    <div style="font-size:24px;font-weight:bold;margin:8px 0 0">${esc(subject)}</div>
  </td></tr>
  <tr><td style="background:#fbf8f2;padding:24px;border-radius:0 0 12px 12px;color:${INK};font-size:16px;line-height:1.55">
    ${toHtml(body)}
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:6px 0 18px"><tr><td style="background:${GOLD};border-radius:10px">
      <a href="${esc(link)}" style="display:inline-block;color:${G};text-decoration:none;font-weight:bold;font-size:17px;padding:13px 24px">${esc(label)}</a>
    </td></tr></table>
    <p style="margin:0;color:${MUT};font-size:14px">Work hard, Fight easy.<br>Team Phuket King</p>
  </td></tr>
  <tr><td style="padding:14px 8px;color:${MUT};font-size:12px;line-height:1.5;text-align:center">You get this as part of your plan${m.group ? ", " + esc(m.group) : ""}.${unsub ? ` <a href="${unsub}" style="color:${MUT}">Unsubscribe</a>` : ""}</td></tr>
</table></td></tr></table></body></html>`;
  const text = [toText(body), "", `${label}: ${link}`, "", "Work hard, Fight easy.", "Team Phuket King", unsub ? `\nUnsubscribe: ${unsub}` : ""].join("\n");
  return { subject, html, text, unsub };
}

async function from() {
  const { data } = await admin.from("app_settings").select("value").eq("key", "welcome_email").maybeSingle();
  try { const w = JSON.parse(data?.value ?? "{}"); return { from: w.from || "Phuket King <hello@app.phuketking.com>", reply_to: w.reply_to || undefined }; }
  catch { return { from: "Phuket King <hello@app.phuketking.com>", reply_to: undefined }; }
}

async function send(to: string, m: Mail, f: { from: string; reply_to?: string }) {
  const b = build(m);
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: f.from, to: [to], reply_to: f.reply_to, subject: b.subject, html: b.html, text: b.text,
        headers: b.unsub ? { "List-Unsubscribe": `<${b.unsub}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } : undefined }),
    });
    const j = await r.json().catch(() => ({}));
    return r.ok ? { ok: true, error: "" } : { ok: false, error: j?.message || `Email service said ${r.status}` };
  } catch (e) { return { ok: false, error: (e as Error).message }; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  try {
    if (b.mode === "auto") {
      const { data: tok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
      if (tok !== true) return json({ error: "Not allowed." }, 401);
      if (!RESEND) return json({ ok: true, skipped: "no email key" });
      const { data: list, error } = await admin.rpc("group_emails_due");
      if (error) return json({ error: error.message });
      const f = await from();
      let sent = 0;
      for (const x of (list ?? []) as (Mail & { member_id: string; item_id: string; customer_id: string; email: string })[]) {
        const r = await send(x.email, x, f);
        await admin.rpc("group_email_mark", { p_member: x.member_id, p_item: x.item_id, p_customer: x.customer_id, p_to: x.email, p_ok: r.ok, p_error: r.error });
        if (r.ok) sent++;
      }
      return json({ ok: true, sent });
    }
    if (b.mode === "test") {
      const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
      const { data: u } = await user.auth.getUser();
      if (!u?.user) return json({ error: "Sign in first." }, 401);
      const { data: s } = await admin.from("staff").select("role,email,name").eq("user_id", u.user.id).eq("active", true).maybeSingle();
      if (!s || !["manager", "coach"].includes(s.role)) return json({ error: "Only coaches and managers can send a test." }, 403);
      if (!RESEND) return json({ error: "Email is not set up yet." });
      const to = u.user.email || s.email;
      if (!to) return json({ error: "Your login has no email." });
      if (!String(b.subject ?? "").trim() || !String(b.text ?? "").trim()) return json({ error: "Write the subject and the message first." });
      const url = /^https:\/\//.test(String(b.url ?? "")) ? String(b.url) : null;
      const r = await send(to, { name: s.name || "", subject: "[Test] " + String(b.subject).slice(0, 200), text: String(b.text).slice(0, 20000), url, button: String(b.button ?? "").slice(0, 60) || null }, await from());
      return r.ok ? json({ ok: true, to }) : json({ error: r.error });
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
