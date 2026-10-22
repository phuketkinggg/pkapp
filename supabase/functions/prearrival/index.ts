// "Get ready" email before a guest arrives, and the one tap sign in from it.
// POST {mode:'auto'}                      the timer (x-sync-token): emails new room guests and website package buyers up to 14 days before arrival
// POST {mode:'send', customer_id, arrival?} a coach or manager sends (or re-sends) it by hand
// POST {mode:'test'}                      a manager sends a sample to their own email
// POST {mode:'claim', token}              the link in the email: returns a one time sign in for the app
import { createClient } from "npm:@supabase/supabase-js@2";

const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const APP = "https://app.phuketking.com/";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const first = (n: unknown) => String(n ?? "").trim().split(/\s+/)[0] || "there";
const day = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" });
const isId = (s: unknown) => /^[0-9a-f-]{36}$/i.test(String(s ?? ""));

type Who = { customer_id: string; name: string; email: string; arrival: string | null; token: string };

async function settings() {
  const { data } = await admin.from("app_settings").select("key,value").in("key", ["welcome_email", "prearrival"]);
  const get = (k: string) => { try { return JSON.parse((data ?? []).find((r) => r.key === k)?.value ?? "{}"); } catch { return {}; } };
  return { we: get("welcome_email"), pa: get("prearrival") };
}

// the email text is editable in the app (Coaching, Arriving soon, Edit the email). {first} is their first name, {arrival} " on Monday 5 November" or nothing.
type Copy = { subject?: string; heading?: string; intro?: string; asks?: string; gets_title?: string; gets?: string; button?: string; after?: string; footer?: string };
const DEFAULT_COPY: Required<Copy> = {
  subject: "Get ready for Phuket King, {first}",
  heading: "Your training starts now, {first}",
  intro: "We can't wait to have you{arrival}. Your Phuket King app is ready. Open it now and take about 5 minutes to tell us:",
  asks: "Why you are coming: fight training, weight loss, fitness or something else\nYour Muay Thai experience and fitness level\nAny injuries, allergies or worries we should know about",
  gets_title: "Then you get",
  gets: "A simple daily plan for the next two weeks, so you arrive ready\nCoaches who already know you and your goals when you walk in",
  button: "Open my app",
  after: "The button signs you straight in, no password needed. Add the app to your home screen when it asks, so it is one tap away.",
  footer: "Work hard, Fight easy.\nTeam Phuket King",
};
function render(w: Who, link: string, hasVideo: boolean, wa: string, copy: Copy = {}) {
  const G = "#1a3325", C = "#f5f0e8", GOLD = "#c9a84c", INK = "#22201c", MUT = "#6b665c";
  const c = { ...DEFAULT_COPY } as Required<Copy>;
  for (const k of Object.keys(DEFAULT_COPY) as (keyof Copy)[]) { const v = copy[k]; if (typeof v === "string" && v.trim()) c[k] = v; }
  const when = w.arrival ? ` on ${day(w.arrival)}` : "";
  const fill = (t: string) => t.replace(/\{\{?\s*(first|name)\s*\}?\}/gi, first(w.name)).replace(/\{\{?\s*arrival\s*\}?\}/gi, when);
  const lines = (t: string) => fill(t).split("\n").map((x) => x.replace(/^[-*]\s*/, "").trim()).filter(Boolean);
  const subject = fill(c.subject);
  const li = (t: string) => `<tr><td style="padding:0 0 10px;color:${INK};font-size:16px;line-height:1.5"><span style="color:${GOLD};font-weight:bold">&#10003;</span>&nbsp; ${esc(t)}</td></tr>`;
  const asks = lines(c.asks);
  const gets = (hasVideo ? ["A video from Coach Tom introducing your coaches"] : []).concat(lines(c.gets));
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:${C};font-family:Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C}"><tr><td align="center" style="padding:20px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px">
  <tr><td style="background:${G};border-radius:12px 12px 0 0;padding:28px 24px;color:#ffffff">
    <div style="color:${GOLD};font-size:13px;letter-spacing:2px;text-transform:uppercase;font-weight:bold">Phuket King Muay Thai</div>
    <div style="font-size:28px;font-weight:bold;margin:8px 0 0">${esc(fill(c.heading))}</div>
  </td></tr>
  <tr><td style="background:#fbf8f2;padding:24px;border-radius:0 0 12px 12px">
    <p style="margin:0 0 18px;color:${INK};font-size:16px;line-height:1.5">${esc(fill(c.intro)).replace(/\n/g, "<br>")}</p>
    ${asks.length ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 8px">${asks.map(li).join("")}</table>` : ""}
    ${gets.length ? `<div style="color:${G};font-size:18px;font-weight:bold;margin:12px 0 10px">${esc(fill(c.gets_title))}</div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 22px">${gets.map(li).join("")}</table>` : ""}
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 12px"><tr><td style="background:${GOLD};border-radius:10px">
      <a href="${esc(link)}" style="display:inline-block;color:${G};text-decoration:none;font-weight:bold;font-size:18px;padding:14px 26px">${esc(fill(c.button))}</a>
    </td></tr></table>
    <p style="margin:0 0 22px;color:${MUT};font-size:14px;line-height:1.5">${esc(fill(c.after)).replace(/\n/g, "<br>")}</p>
    <p style="margin:0;color:${INK};font-size:15px;line-height:1.5">Questions before you travel? <a href="https://wa.me/${esc(wa)}" style="color:${G};font-weight:bold">WhatsApp us</a>.</p>
    <p style="margin:20px 0 0;color:${MUT};font-size:14px">${esc(fill(c.footer)).replace(/\n/g, "<br>")}</p>
  </td></tr>
</table></td></tr></table></body></html>`;
  const text = [fill(c.heading), "", fill(c.intro), ...asks.map((g) => "- " + g), "", fill(c.gets_title) + ":", ...gets.map((g) => "- " + g), "",
    `${fill(c.button)}: ${link}`, fill(c.after), "", `Questions? WhatsApp us: https://wa.me/${wa}`, "", fill(c.footer)].join("\n");
  return { subject, html, text };
}

async function send(w: Who, link: string) {
  const { we, pa } = await settings();
  const m = render(w, link, !!pa.video_url, String(we.whatsapp || "66969076150").replace(/\D/g, ""), pa.email || {});
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: we.from || "Phuket King <hello@app.phuketking.com>", to: [w.email], reply_to: we.reply_to || undefined, subject: m.subject, html: m.html, text: m.text }),
    });
    const j = await r.json().catch(() => ({}));
    return r.ok ? { ok: true } : { ok: false, error: j?.message || `Email service said ${r.status}` };
  } catch (e) { return { ok: false, error: (e as Error).message }; }
}

async function sendAndMark(w: Who) {
  const r = await send(w, `${APP}?ready=${w.token}`);
  const { data: row } = await admin.from("prearrival").select("tries").eq("customer_id", w.customer_id).maybeSingle();
  await admin.from("prearrival").update(r.ok ? { sent_at: new Date().toISOString(), sent_to: w.email, send_error: null, tries: (row?.tries ?? 0) + 1 }
    : { send_error: r.error, tries: (row?.tries ?? 0) + 1 }).eq("customer_id", w.customer_id);
  return r;
}

async function staffRole(req: Request) {
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const { data } = await user.auth.getUser();
  if (!data?.user) return { user, role: null as string | null, email: null as string | null };
  const { data: s } = await admin.from("staff").select("role,email").eq("user_id", data.user.id).eq("active", true).maybeSingle();
  return { user, role: s?.role ?? null, email: data.user.email ?? s?.email ?? null };
}

// the email link: make sure the guest has a login linked to them, then hand back a one time sign in
async function claim(token: string) {
  const { data: c, error } = await admin.rpc("prearrival_claim", { p_token: token });
  if (error || !c) return { error: "This link has expired. Sign in with your email below, or ask us for a new link." };
  let email = String(c.email || "");
  let uid: string | null = c.user_id;
  if (uid) {
    const { data: u } = await admin.auth.admin.getUserById(uid);
    if (u?.user?.email) email = u.user.email; else uid = null;
  }
  if (!uid) {
    const { data: found } = await admin.rpc("admin_auth_lookup", { p_email: email });
    if (found?.id) uid = found.id;
    else {
      const { data: made, error: e2 } = await admin.auth.admin.createUser({ email, email_confirm: true, user_metadata: { name: c.name } });
      if (e2 || !made?.user) return { error: "Your login could not be made. Sign in with your email below." };
      uid = made.user.id;
    }
    const { data: st } = await admin.from("staff").select("id").eq("user_id", uid).maybeSingle();
    if (st) return { error: "Sign in with your email below." };
    await admin.from("customers").update({ user_id: uid }).eq("id", c.customer_id).is("user_id", null);
  }
  const { data: link, error: e3 } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const hash = (link as { properties?: { hashed_token?: string } } | null)?.properties?.hashed_token;
  if (e3 || !hash) return { error: "Sign in with your email below." };
  return { token_hash: hash, email };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  try {
    if (b.mode === "claim") {
      const t = String(b.token ?? "");
      if (!/^[0-9a-f]{64}$/.test(t)) return json({ error: "This link is not complete. Open it again from the email." });
      return json(await claim(t));
    }
    if (b.mode === "auto") {
      const { data: tok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
      if (tok !== true) return json({ error: "Not allowed." }, 401);
      if (!RESEND) return json({ ok: true, skipped: "no email key" });
      const { data: list, error } = await admin.rpc("prearrival_due");
      if (error) return json({ error: error.message });
      let sent = 0;
      for (const w of (list ?? []) as Who[]) { if ((await sendAndMark(w)).ok) sent++; }
      return json({ ok: true, sent });
    }
    const me = await staffRole(req);
    if (b.mode === "send") {
      if (me.role !== "manager" && me.role !== "coach") return json({ error: "Only coaches and managers can send this." }, 401);
      if (!RESEND) return json({ error: "Email sending is not set up yet." });
      if (!isId(b.customer_id)) return json({ error: "Choose a customer." });
      const arrival = /^\d{4}-\d{2}-\d{2}$/.test(String(b.arrival ?? "")) ? String(b.arrival) : null;
      const { data: w, error } = await me.user.rpc("prearrival_invite", { p_customer: b.customer_id, p_arrival: arrival });
      if (error) return json({ error: error.message });
      const r = await sendAndMark(w as Who);
      return r.ok ? json({ ok: true, to: (w as Who).email }) : json({ error: "The email did not go: " + r.error });
    }
    if (b.mode === "test") {
      if (me.role !== "manager") return json({ error: "Only a manager can do this." }, 401);
      if (!RESEND) return json({ error: "Email sending is not set up yet." });
      if (!me.email) return json({ error: "Your login has no email." });
      const today = new Date(Date.now() + 7 * 3600e3 + 10 * 864e5).toISOString().slice(0, 10);
      const r = await send({ customer_id: "", name: "Alex", email: me.email, arrival: today, token: "" }, APP);
      return r.ok ? json({ ok: true, to: me.email }) : json({ error: "The email did not go: " + r.error });
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
