// Muay Friend website forms. Saves the enquiry and emails it to the owner.
// POST {name, email, gym?, country?, members?, phone?, message?, website (honeypot)}  ->  {ok:true}            "Get more info"
// POST {plan:"free", name, email, gym, country, phone, members?, social?, message?, lang?}  ->  {ok:true, waitlist}  "Start free"
//   The free version has a set number of spots (app_settings mf_free_cap, default 50). When they are taken, sign-ups go on
//   a waiting list. The gym gets a welcome email from Muay Friend (only from hello@muayfriend.com, never another brand).
// GET  ->  {free_left}  how many free spots are left, for the website.
// Public (no login). Spam guards: honeypot, field checks, max 5 per hour per visitor, 60 per hour in total.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const TO = "hello@muayfriend.com";
const KEY = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, apikey, x-client-info, authorization", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const clip = (x: unknown, n: number) => String(x ?? "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim().slice(0, n);
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function hash(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("mf-lead:" + s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

async function freeLeft() {
  const { data } = await admin.from("app_settings").select("value").eq("key", "mf_free_cap").maybeSingle();
  const cap = Math.max(0, parseInt(String(data?.value ?? "50"), 10) || 0);
  const { count } = await admin.from("mf_leads").select("id", { count: "exact", head: true }).eq("plan", "free").neq("status", "rejected");
  return Math.max(0, cap - (count ?? 0));
}

async function resend(msg: Record<string, unknown>) {
  if (!KEY) return { ok: false, err: "no RESEND_API_KEY" };
  try {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" }, body: JSON.stringify(msg) });
    return r.ok ? { ok: true, err: "" } : { ok: false, err: (await r.text().catch(() => "")).slice(0, 300) || String(r.status) };
  } catch (e) { return { ok: false, err: String(e).slice(0, 300) }; }
}

// the welcome email to the gym (English or Thai)
function welcome(name: string, gym: string, waitlist: boolean, th: boolean) {
  const first = name.split(/\s+/)[0] || name;
  const en = waitlist ? [
    `Hi ${first},`,
    `Thanks for signing up ${gym} for Muay Friend. All our free spots are taken right now, so you are on the waiting list. We will email you as soon as a spot opens.`,
    `If you would rather start now, reply to this email and we will tell you about our paid plans.`,
  ] : [
    `Hi ${first},`,
    `Welcome to Muay Friend. We are setting up ${gym} now, and your free gym app will be ready within 24 hours. We will email you the link and your login.`,
    `The free version includes check-ins, packages, selling and appointments, for up to 15 members and 2 staff.`,
    `While you wait, have a look around the live demo: https://muayfriend.com/demo/`,
    `Questions? Just reply to this email.`,
  ];
  const tl = waitlist ? [
    `สวัสดีคุณ${first}`,
    `ขอบคุณที่สมัคร Muay Friend ให้ ${gym} ตอนนี้ที่ว่างสำหรับเวอร์ชันฟรีเต็มแล้ว คุณอยู่ในรายชื่อรอ เราจะอีเมลแจ้งทันทีที่มีที่ว่าง`,
    `หากต้องการเริ่มใช้เลย ตอบกลับอีเมลนี้ได้ แล้วเราจะแนะนำแพ็กเกจแบบชำระเงินให้`,
  ] : [
    `สวัสดีคุณ${first}`,
    `ยินดีต้อนรับสู่ Muay Friend เรากำลังตั้งค่า ${gym} ให้คุณ แอปยิมฟรีของคุณจะพร้อมใช้งานภายใน 24 ชั่วโมง เราจะอีเมลลิงก์และข้อมูลเข้าสู่ระบบให้`,
    `เวอร์ชันฟรีมีเช็คอิน แพ็กเกจ งานขาย และการนัดหมาย สำหรับสมาชิกสูงสุด 15 คนและพนักงาน 2 คน`,
    `ระหว่างรอ ลองดูเดโมได้ที่ https://muayfriend.com/demo/`,
    `มีคำถาม ตอบกลับอีเมลนี้ได้เลย`,
  ];
  const lines = th ? tl : en, sign = th ? "ทีม Muay Friend" : "The Muay Friend team";
  const text = lines.join("\n\n") + "\n\n" + sign + "\nhttps://muayfriend.com";
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.55;color:#171B23">` +
    lines.map((l) => `<p style="margin:0 0 14px">${esc(l).replace(/https:\/\/muayfriend\.com\/demo\//, '<a href="https://muayfriend.com/demo/" style="color:#2F5BD3">muayfriend.com/demo</a>')}</p>`).join("") +
    `<p style="margin:0">${esc(sign)}<br><a href="https://muayfriend.com" style="color:#2F5BD3">muayfriend.com</a></p></div>`;
  const subject = waitlist ? (th ? "คุณอยู่ในรายชื่อรอ Muay Friend" : "You are on the Muay Friend waiting list") : (th ? "ยินดีต้อนรับสู่ Muay Friend" : "Welcome to Muay Friend");
  return { subject, text, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method === "GET") return json({ free_left: await freeLeft().catch(() => null) });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    const b = await req.json().catch(() => ({}));
    if (clip(b.website, 200)) return json({ ok: true }); // bots fill the hidden field
    const free = b.plan === "free", th = b.lang === "th";
    const name = clip(b.name, 100), email = clip(b.email, 160).toLowerCase();
    if (!name) return json({ error: th ? "กรุณาใส่ชื่อของคุณ" : "Please add your name." }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return json({ error: th ? "กรุณาตรวจสอบอีเมล" : "Please check your email address." }, 400);
    const gym = clip(b.gym, 140);
    if (free && !gym) return json({ error: th ? "กรุณาใส่ชื่อยิม" : "Please add your gym name." }, 400);
    const row: Record<string, unknown> = { name, email, gym: gym || null, country: clip(b.country, 80) || null, members: clip(b.members, 40) || null,
      phone: clip(b.phone, 40) || null, message: clip(b.message, 3000) || null, source: clip(b.source, 120) || null, social: clip(b.social, 200) || null,
      ip_hash: await hash(req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0] ?? "unknown") };
    const hour = new Date(Date.now() - 3600_000).toISOString();
    const [{ count: mine }, { count: all }] = await Promise.all([
      admin.from("mf_leads").select("id", { count: "exact", head: true }).eq("ip_hash", row.ip_hash).gte("created_at", hour),
      admin.from("mf_leads").select("id", { count: "exact", head: true }).gte("created_at", hour)]);
    if ((mine ?? 0) >= 5 || (all ?? 0) >= 60) return json({ error: th ? "ขอบคุณ เราได้รับข้อมูลของคุณแล้ว จะติดต่อกลับเร็วๆ นี้" : "Thanks, we already have your details. We will be in touch soon." }, 429);

    let waitlist = false;
    if (free) {
      const { count: dup } = await admin.from("mf_leads").select("id", { count: "exact", head: true }).eq("email", email).in("plan", ["free", "free_waitlist"]);
      if ((dup ?? 0) > 0) return json({ ok: true, waitlist: false, again: true });
      waitlist = (await freeLeft()) <= 0;
      row.plan = waitlist ? "free_waitlist" : "free";
    }
    const { data: saved, error } = await admin.from("mf_leads").insert(row).select("id").single();
    if (error) return json({ error: th ? "เกิดข้อผิดพลาด กรุณาลองอีกครั้ง" : "Something went wrong. Please try again." }, 500);

    // to the owner
    const lines: [string, unknown][] = [["Name", row.name], ["Email", row.email], ["Gym", row.gym], ["Country", row.country], ["Members", row.members], ["Phone or WhatsApp", row.phone], ["Instagram or website", row.social], ["Message", row.message]];
    const kind = free ? (waitlist ? "Free version, WAITING LIST" : "FREE VERSION sign-up: set up within 24 hours") : "New Muay Friend enquiry";
    const html = `<h2 style="font-family:sans-serif">${kind}</h2><table style="font-family:sans-serif;font-size:15px">${lines.filter((l) => l[1]).map(([k, v]) => `<tr><td style="padding:4px 14px 4px 0;color:#666;vertical-align:top">${k}</td><td style="padding:4px 0;white-space:pre-wrap">${esc(String(v))}</td></tr>`).join("")}</table><p style="font-family:sans-serif;color:#666">Reply to this email to answer them directly.</p>`;
    const text = kind + "\n\n" + lines.filter((l) => l[1]).map(([k, v]) => `${k}: ${v}`).join("\n");
    const subj = free ? `${waitlist ? "Free waiting list" : "FREE sign-up"}: ${row.gym}` : `Muay Friend enquiry: ${row.gym || row.name}`;
    const o = await resend({ from: "Muay Friend <hello@app.phuketking.com>", to: [TO], reply_to: row.email, subject: subj, html, text });
    const upd: Record<string, unknown> = { emailed: o.ok, email_error: o.ok ? null : o.err };

    // to the gym, only from the Muay Friend address
    if (free) {
      const w = welcome(name, String(row.gym), waitlist, th);
      const g = await resend({ from: "Muay Friend <hello@muayfriend.com>", to: [email], reply_to: TO, subject: w.subject, html: w.html, text: w.text });
      upd.welcomed = g.ok; upd.welcome_error = g.ok ? null : g.err;
    }
    await admin.from("mf_leads").update(upd).eq("id", saved.id);
    return json({ ok: true, waitlist });
  } catch (_e) { return json({ error: "Something went wrong. Please try again." }, 500); }
});
