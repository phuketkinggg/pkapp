// One email to one person, written in the app by the owner or an admin (Contacts, a contact's page, Send an email).
// POST {id}  signed-in manager: sends that saved draft from hello@phuketking.com (Resend). Replies go to hello@phuketking.com.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (!RESEND) return json({ error: "Email sending is not set up yet. Add RESEND_API_KEY in Supabase." });
  const b = await req.json().catch(() => ({}));
  if (!/^[0-9a-f-]{36}$/i.test(String(b.id ?? ""))) return json({ error: "Save the email first." });
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const { data: m, error } = await user.rpc("email_one_claim", { p_id: b.id });
  if (error) return json({ error: error.message });
  const e = m as { id: string; to: string; subject: string; body: string; from_name?: string };
  const who = String(e.from_name || "").replace(/[<>"\r\n,]/g, "").trim();
  const from = (who ? who + ", Phuket King Muay Thai" : "Phuket King Muay Thai") + " <hello@phuketking.com>";
  let ok = false, rid = "", err = "";
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [e.to], reply_to: "hello@phuketking.com", subject: e.subject, html: toHtml(e.body), text: e.body }),
    });
    const j = await r.json().catch(() => ({}));
    ok = r.ok; rid = String((j as { id?: string }).id ?? ""); err = ok ? "" : String((j as { message?: string }).message ?? ("Error " + r.status));
  } catch (x) { err = String(x).slice(0, 200); }
  await admin.from("sent_emails").update(ok ? { status: "sent", sent_at: new Date().toISOString(), resend_id: rid, error: null } : { status: "failed", error: err.slice(0, 300) }).eq("id", e.id);
  return ok ? json({ ok: true }) : json({ error: "Not sent: " + err });
});
