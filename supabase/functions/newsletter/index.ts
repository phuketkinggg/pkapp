// Newsletters by email (Resend). Everyone with an email is included unless they unsubscribed; a newsletter can be limited to tags.
// POST {mode:'test', id}   signed-in manager: sends one copy to the manager's own email
// POST {mode:'send', id}   signed-in manager: sends the next batch (up to 300); the app calls again until left = 0
// GET  ?u=<token>          unsubscribe link from the email (shows a small page)
// POST ?u=<token>          one-click unsubscribe from the mail app (List-Unsubscribe)
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const FROM = "Phuket King Muay Thai <hello@app.phuketking.com>";
const SELF = URL_ + "/functions/v1/newsletter";
const SITE = "https://www.phuketking.com";
const LOGO = "https://phuketking-site.pages.dev/img/wordmark.png";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

// the same simple format as the blog: blank line = paragraph, ## heading, - list, **bold**, *italic*, [text](https://link), ![caption](https://photo)
function inl(t: string) {
  return esc(t).replace(/\[([^\]]+)\]\((https:\/\/[^)\s]+)\)/g, (_m, a, u) => `<a href="${u.replace(/&amp;/g, "&").replace(/"/g, "%22")}" style="color:#D8001B">${a}</a>`)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/\*([^*\n]+)\*/g, "<em>$1</em>").replace(/\n/g, "<br>");
}
function toHtml(md: string) {
  return String(md || "").replace(/\r/g, "").split(/\n\s*\n/).map((b) => {
    b = b.trim(); if (!b) return "";
    let m = b.match(/^!\[([^\]]*)\]\((https:\/\/[^)\s]+)\)$/);
    if (m) return `<p style="margin:0 0 18px"><img src="${esc(m[2])}" alt="${esc(m[1])}" style="max-width:100%;height:auto;border-radius:8px;display:block"></p>`;
    if (/^### /.test(b)) return `<h3 style="font-size:18px;margin:22px 0 8px">${inl(b.slice(4))}</h3>`;
    if (/^##? /.test(b)) return `<h2 style="font-size:22px;margin:26px 0 10px">${inl(b.replace(/^##? /, ""))}</h2>`;
    const lines = b.split("\n");
    if (lines.every((l) => /^[-*] /.test(l))) return `<ul style="margin:0 0 18px;padding-left:22px">${lines.map((l) => `<li style="margin:0 0 6px">${inl(l.slice(2))}</li>`).join("")}</ul>`;
    if (lines.every((l) => /^\d+[.)] /.test(l))) return `<ol style="margin:0 0 18px;padding-left:22px">${lines.map((l) => `<li style="margin:0 0 6px">${inl(l.replace(/^\d+[.)] /, ""))}</li>`).join("")}</ol>`;
    if (/^> /.test(b)) return `<blockquote style="margin:0 0 18px;padding:10px 16px;border-left:4px solid #D8001B;background:#F9F3ED">${inl(b.replace(/^> ?/gm, ""))}</blockquote>`;
    return `<p style="margin:0 0 18px">${inl(b)}</p>`;
  }).join("");
}
function toText(md: string) {
  return String(md || "").replace(/!\[([^\]]*)\]\(([^)]+)\)/g, "").replace(/\[([^\]]+)\]\(([^)]+)\)/g, "$1 ($2)").replace(/\*\*([^*]+)\*\*/g, "$1").replace(/^#+ /gm, "").trim();
}
function first(name: string) { const f = String(name || "").trim().split(/\s+/)[0]; return f && f.length < 30 ? f : "there"; }
function build(n: { subject: string; preview?: string; body: string }, p: { name: string; token: string }) {
  const body = n.body.replace(/\{\{\s*name\s*\}\}/gi, first(p.name));
  const unsub = `${SELF}?u=${p.token}`;
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(n.subject)}</title></head>
<body style="margin:0;background:#F2EDE7;font-family:Arial,Helvetica,sans-serif;color:#171B23">
<span style="display:none;max-height:0;overflow:hidden;opacity:0">${esc(n.preview || "")}</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F2EDE7"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:10px;overflow:hidden">
<tr><td style="background:#171B23;padding:20px 28px"><a href="${SITE}"><img src="${LOGO}" alt="Phuket King Muay Thai" width="200" style="display:block;width:200px;height:auto;border:0"></a></td></tr>
<tr><td style="padding:28px 28px 8px;font-size:16px;line-height:1.6">${toHtml(body)}</td></tr>
<tr><td style="padding:8px 28px 28px"><a href="${SITE}" style="display:inline-block;background:#D8001B;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 22px;border-radius:4px">Visit Phuket King</a></td></tr>
<tr><td style="background:#F9F3ED;padding:18px 28px;font-size:12px;line-height:1.6;color:#5E6470">
Phuket King Muay Thai, Kathu, Phuket, Thailand. Reply to this email or WhatsApp +66 61 515 5947.<br>
You get this because you trained, stayed or bought with us. <a href="${unsub}" style="color:#5E6470">Unsubscribe</a></td></tr>
</table></td></tr></table></body></html>`;
  const text = toText(body) + `\n\n--\nPhuket King Muay Thai, Kathu, Phuket\nUnsubscribe: ${unsub}`;
  return { html, text, unsub };
}
async function sendBatch(n: { subject: string; preview?: string; body: string }, people: { id: string; email: string; name: string; token: string }[]) {
  const msgs = people.map((p) => { const b = build(n, p); return { from: FROM, to: [p.email], reply_to: "hello@phuketking.com", subject: n.subject, html: b.html, text: b.text,
    headers: { "List-Unsubscribe": `<${b.unsub}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } }; });
  const r = await fetch("https://api.resend.com/emails/batch", { method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" }, body: JSON.stringify(msgs) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) return people.map((p) => ({ id: p.id, email: p.email, ok: false, error: (j?.message ?? `Resend said ${r.status}`).slice(0, 300) }));
  return people.map((p) => ({ id: p.id, email: p.email, ok: true }));
}
function page(title: string, msg: string) {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title></head>
<body style="margin:0;font-family:Arial,Helvetica,sans-serif;background:#171B23;color:#fff;display:flex;min-height:100vh;align-items:center;justify-content:center">
<div style="max-width:460px;padding:32px;text-align:center"><img src="${LOGO}" alt="Phuket King Muay Thai" width="220" style="width:220px;height:auto"><h1 style="font-size:24px;margin:28px 0 12px">${esc(title)}</h1><p style="line-height:1.6;opacity:.85">${msg}</p>
<p><a href="${SITE}" style="color:#fff">phuketking.com</a></p></div></body></html>`, { headers: { "Content-Type": "text/html; charset=utf-8" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const u = new URL(req.url).searchParams.get("u");
  if (u) {
    if (!/^[0-9a-f-]{36}$/i.test(u)) return page("Link not valid", "This unsubscribe link is not complete. Reply to any of our emails and we will take you off the list.");
    const { data } = await admin.rpc("newsletter_unsubscribe", { p_token: u });
    if (req.method === "POST") return new Response("ok");
    return data?.ok ? page("You are unsubscribed", `We will not send newsletters to ${esc(data.email)} any more. You still get emails about your own bookings. Changed your mind? Turn emails back on in the Phuket King app, under My details.`)
      : page("Link not valid", "We could not find that email. Reply to any of our emails and we will take you off the list.");
  }
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (!RESEND) return json({ error: "Email sending is not set up yet. Add RESEND_API_KEY in Supabase." });
  const b = await req.json().catch(() => ({}));
  if (!/^[0-9a-f-]{36}$/i.test(String(b.id ?? ""))) return json({ error: "Choose a newsletter." });
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const test = b.mode === "test";
  if (!test && b.mode !== "send") return json({ error: "Unknown request." }, 400);
  const { data: ok, error } = await user.rpc("newsletter_send_ok", { p_id: b.id, p_test: test });
  if (error) return json({ error: error.message });
  const { data: bt, error: e2 } = await admin.rpc("newsletter_batch", { p_id: b.id, p_limit: test ? 1 : 300 });
  if (e2 || !bt?.n) return json({ error: e2?.message ?? "That newsletter was not found." });
  if (test) {
    const me = (ok as { me?: string }).me;
    if (!me) return json({ error: "Your staff account has no email to send the test to." });
    const res = await sendBatch({ ...bt.n, subject: "[Test] " + bt.n.subject }, [{ id: "test", email: me, name: "", token: "00000000-0000-0000-0000-000000000000" }]);
    return res[0].ok ? json({ ok: true, to: me }) : json({ error: res[0].error });
  }
  const people = bt.people as { id: string; email: string; name: string; token: string }[];
  const out: { id: string; email: string; ok: boolean; error?: string }[] = [];
  for (let i = 0; i < people.length; i += 100) out.push(...await sendBatch(bt.n, people.slice(i, i + 100)));
  await admin.rpc("newsletter_record", { p_id: b.id, p_rows: out, p_done: false });
  const allFailed = out.length > 0 && out.every((x) => !x.ok);
  const { data: after } = await admin.rpc("newsletter_batch", { p_id: b.id, p_limit: 1 });
  const more = !allFailed && ((after?.people as unknown[]) ?? []).length > 0;
  if (!more && !allFailed) await admin.rpc("newsletter_record", { p_id: b.id, p_rows: [], p_done: true });
  return json({ sent: out.filter((x) => x.ok).length, failed: out.filter((x) => !x.ok).length, total: bt.total, more, error: out.find((x) => !x.ok)?.error ?? null });
});
