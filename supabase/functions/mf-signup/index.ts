// Muay Friend free: instant sign-up from the website. Runs in the shared free project (bnglnfdgptvnmugntiom).
// POST {gym, name, email, phone, country, members?, social?, lang?, website (honeypot)}
//   New email: makes the account and the gym, and answers {ok, slug, go} where go is a one-time link that signs the owner
//   straight in to their new app. A welcome email with the app address follows.
//   Email that already has an account: makes the gym and emails a sign-in link (never signs in without the inbox): {ok, slug, sent}.
//   Already owns a gym: emails a sign-in link to it: {ok, slug, again, sent}.
//   No free spots left: {full:true} (the website then puts them on the waiting list).
// GET -> {free_left}
// Invites (launch list): add invite_key (mf.cfg invite_key, only readable in the database): the link is emailed, no visitor limit.
// Public. Spam guards: honeypot, field checks, max 3 per hour per visitor, 30 per hour in total, 3 gyms per email.
// Emails go from hello@muayfriend.com through Resend (RESEND_API_KEY in this project's secrets).
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const APP = "https://muayfriend.com/app/";
const FROM = "Muay Friend <hello@muayfriend.com>", TEAM = "hello@muayfriend.com";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, apikey, x-client-info, authorization", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const clip = (x: unknown, n: number) => String(x ?? "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim().slice(0, n);
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function hash(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("mf-signup:" + s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

async function resend(msg: Record<string, unknown>) {
  if (!KEY) return { ok: false, err: "no RESEND_API_KEY" };
  try {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" }, body: JSON.stringify(msg) });
    return r.ok ? { ok: true, err: "" } : { ok: false, err: (await r.text().catch(() => "")).slice(0, 300) || String(r.status) };
  } catch (e) { return { ok: false, err: String(e).slice(0, 300) }; }
}

// a one-time sign-in link that opens the gym's app (the app checks the code itself)
async function signInLink(email: string, slug: string) {
  const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email, options: { redirectTo: APP + "?g=" + slug } });
  const h = data?.properties?.hashed_token;
  if (error || !h) throw new Error("link: " + (error?.message ?? "no token"));
  return `${APP}?g=${slug}&token_hash=${encodeURIComponent(h)}&type=magiclink`;
}

function mail(th: boolean, first: string, gym: string, slug: string, link: string | null) {
  const app = APP + "?g=" + slug;
  const en = [
    `Hi ${first},`,
    `Your gym app for ${gym} is ready.`,
    link ? `Tap here to sign in: ${link}` : `You are signed in on the phone you signed up on.`,
    `Your app address is ${app}. Save it to your home screen, and send it to your members and staff: they open it, type their email, and they are in.`,
    link ? `The sign in link works once. To sign in again later, open your app address and type your email.` : `To sign in on another phone or computer, open your app address and type your email.`,
    `Free includes check-ins, packages, selling and appointments, for up to 15 members and 2 staff. When you want more, everything moves with you to a paid plan.`,
    `Questions? Just reply to this email.`,
  ];
  const tl = [
    `สวัสดีคุณ${first}`,
    `แอปยิมของ ${gym} พร้อมใช้แล้ว`,
    link ? `แตะที่นี่เพื่อเข้าสู่ระบบ: ${link}` : `คุณเข้าสู่ระบบในโทรศัพท์ที่ใช้สมัครแล้ว`,
    `ที่อยู่แอปของคุณคือ ${app} เพิ่มไว้ที่หน้าจอโฮม แล้วส่งให้สมาชิกและพนักงาน พวกเขาเปิดลิงก์ ใส่อีเมล ก็เข้าใช้ได้เลย`,
    link ? `ลิงก์เข้าสู่ระบบใช้ได้ครั้งเดียว ครั้งต่อไปให้เปิดที่อยู่แอปแล้วใส่อีเมล` : `หากต้องการเข้าใช้ในโทรศัพท์หรือคอมพิวเตอร์เครื่องอื่น ให้เปิดที่อยู่แอปแล้วใส่อีเมล`,
    `เวอร์ชันฟรีมีเช็คอิน แพ็กเกจ งานขาย และการนัดหมาย สำหรับสมาชิกสูงสุด 15 คนและพนักงาน 2 คน เมื่อต้องการมากกว่านี้ ย้ายไปแพ็กเกจแบบชำระเงินได้โดยข้อมูลอยู่ครบ`,
    `มีคำถาม ตอบกลับอีเมลนี้ได้เลย`,
  ];
  const lines = th ? tl : en, sign = th ? "ทีม Muay Friend" : "The Muay Friend team";
  const text = lines.join("\n\n") + "\n\n" + sign + "\nhttps://muayfriend.com";
  const linkify = (l: string) => {
    let s = esc(l);
    if (link) s = s.replace(esc(link), `<a href="${esc(link)}" style="display:inline-block;margin-top:6px;background:#2F5BD3;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">${th ? "เปิดแอปยิมของคุณ" : "Open your gym app"}</a>`);
    return s.replace(esc(app), `<a href="${esc(app)}" style="color:#2F5BD3">${esc(app.replace("https://", ""))}</a>`);
  };
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.55;color:#171B23">` +
    lines.map((l) => `<p style="margin:0 0 14px">${linkify(l)}</p>`).join("") +
    `<p style="margin:0">${esc(sign)}<br><a href="https://muayfriend.com" style="color:#2F5BD3">muayfriend.com</a></p></div>`;
  return { subject: th ? `แอปยิมของ ${gym} พร้อมแล้ว` : `Your ${gym} app is ready`, text, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method === "GET") {
    const { data } = await admin.rpc("mf_free_left");
    return json({ free_left: typeof data === "number" ? data : null });
  }
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  let ip = "", email = "", gym = "";
  try {
    const b = await req.json().catch(() => ({}));
    if (clip(b.website, 200)) return json({ ok: true, sent: true }); // bots fill the hidden field
    const th = b.lang === "th", T = (en: string, t: string) => (th ? t : en);
    const name = clip(b.name, 100); email = clip(b.email, 160).toLowerCase(); gym = clip(b.gym, 80);
    const phone = clip(b.phone, 40), country = clip(b.country, 80);
    if (!gym) return json({ error: T("Please add your gym name.", "กรุณาใส่ชื่อยิม") }, 400);
    if (!name) return json({ error: T("Please add your name.", "กรุณาใส่ชื่อของคุณ") }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return json({ error: T("Please check your email address.", "กรุณาตรวจสอบอีเมล") }, 400);
    ip = await hash(req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0] ?? "unknown");

    const { data: c, error: ce } = await admin.rpc("mf_signup_check", { p_email: email, p_ip: ip });
    if (ce || !c) throw new Error("check: " + (ce?.message ?? "none"));
    const first = name.split(/\s+/)[0] || name;
    const owns = (c.owns ?? []) as { slug: string; name: string }[];
    const log = (slug: string | null, result: string, info?: unknown) => admin.rpc("mf_signup_log", { p_ip: ip, p_email: email, p_gym: gym, p_slug: slug, p_result: result, p_info: info ?? null });

    // invites from the Muay Friend team (people on the launch list): no visitor limit, the link always goes by email
    const { data: ik } = await admin.rpc("mf_invite_ok", { p_key: clip(b.invite_key, 100) });
    const invite = ik === true;
    if (!invite && ((c.ip_hour ?? 0) >= 3 || (c.all_hour ?? 0) >= 30)) {
      await log(null, "too many");
      return json({ error: T("Too many sign-ups right now. Please try again in an hour, or email hello@muayfriend.com.", "มีการสมัครมากเกินไป กรุณาลองใหม่ในอีกหนึ่งชั่วโมง หรืออีเมลมาที่ hello@muayfriend.com") }, 429);
    }

    // the same gym again (or the per-email limit): send them in to the gym they already have
    const same = owns.find((g) => g.name.toLowerCase() === gym.toLowerCase());
    if (same || owns.length >= (c.per_email ?? 3)) {
      const g = same ?? owns[owns.length - 1];
      const link = await signInLink(email, g.slug);
      const m = mail(th, first, g.name, g.slug, link);
      const s = await resend({ from: FROM, to: [email], reply_to: TEAM, subject: m.subject, html: m.html, text: m.text });
      await log(g.slug, s.ok ? "again, link sent" : "again, email failed: " + s.err);
      return json({ ok: true, slug: g.slug, again: true, sent: s.ok });
    }
    if ((c.free_left ?? 0) <= 0) { await log(null, "full"); return json({ full: true }); }

    // the account: a new email gets one straight away and is signed in now; an existing account proves it owns the inbox first
    let uid = c.user_id as string | null;
    const isNew = !uid;
    if (isNew) {
      const { data: u, error: ue } = await admin.auth.admin.createUser({ email, email_confirm: true, user_metadata: { full_name: name, gym } });
      if (ue || !u?.user) throw new Error("user: " + (ue?.message ?? "none"));
      uid = u.user.id;
    }
    const { data: made, error: me } = await admin.rpc("mf_make_gym", { p_name: gym, p_owner_email: email, p_owner_name: name, p_owner_user: uid, p_country: country || null, p_phone: phone || null });
    if (me || !made?.slug) throw new Error("gym: " + (me?.message ?? "none"));
    const slug = made.slug as string;
    const link = await signInLink(email, slug);

    // emails: the gym (sign-in link only when it has to come from the inbox) and the Muay Friend team
    const m = mail(th, first, gym, slug, isNew && !invite ? null : link);
    const s = await resend({ from: FROM, to: [email], reply_to: TEAM, subject: m.subject, html: m.html, text: m.text });
    const rows: [string, string][] = [["Gym", gym], ["App", APP + "?g=" + slug], ["Name", name], ["Email", email], ["Phone or WhatsApp", phone], ["Country", country],
      ["Members", clip(b.members, 40)], ["Instagram or website", clip(b.social, 200)], ["Language", th ? "Thai" : "English"], ["Welcome email", s.ok ? "sent" : "failed: " + s.err]];
    await resend({ from: FROM, to: [TEAM], reply_to: email, subject: `New free gym: ${gym}`,
      html: `<h2 style="font-family:sans-serif">New free gym, ready now</h2><table style="font-family:sans-serif;font-size:15px">${rows.filter((r) => r[1]).map(([k, v]) => `<tr><td style="padding:4px 14px 4px 0;color:#666">${k}</td><td style="padding:4px 0">${esc(v)}</td></tr>`).join("")}</table>`,
      text: rows.filter((r) => r[1]).map(([k, v]) => `${k}: ${v}`).join("\n") });
    await log(slug, (invite ? "invited, link emailed" : isNew ? "made, signed in" : "made, link emailed") + (s.ok ? "" : "; welcome failed: " + s.err),
      { phone, country, members: clip(b.members, 40), social: clip(b.social, 200), lang: th ? "th" : "en" });
    return isNew && !invite ? json({ ok: true, slug, go: link, sent: s.ok }) : json({ ok: true, slug, sent: s.ok });
  } catch (e) {
    try { await admin.rpc("mf_signup_log", { p_ip: ip, p_email: email, p_gym: gym, p_slug: null, p_result: "error: " + String(e).slice(0, 250) }); } catch (_) { /* logging only */ }
    return json({ error: "Something went wrong. Please try again, or email hello@muayfriend.com." }, 500);
  }
});
