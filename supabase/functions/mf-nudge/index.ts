// Muay Friend: friendly emails to new free gyms whose app is still empty (no packages, timetable or members),
// on day 1, day 4 and day 10 after signing up, offering to set it up for them. Stops as soon as they start using it.
// Called once a day by pg_cron (job mf-nudge) with the key in mf.cfg nudge_key. Free project only.
// Emails go from hello@muayfriend.com through Resend; replies come to the Muay Friend team. A copy of each goes to the team.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const APP = "https://muayfriend.com/app/";
const FROM = "Muay Friend <hello@muayfriend.com>", TEAM = "hello@muayfriend.com";
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function resend(msg: Record<string, unknown>) {
  if (!KEY) return { ok: false, err: "no RESEND_API_KEY" };
  try {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" }, body: JSON.stringify(msg) });
    return r.ok ? { ok: true, err: "" } : { ok: false, err: (await r.text().catch(() => "")).slice(0, 200) || String(r.status) };
  } catch (e) { return { ok: false, err: String(e).slice(0, 200) }; }
}

type Gym = { slug: string; gym: string; email: string; step: number; lang: string; first: string };

function mail(g: Gym) {
  const th = g.lang === "th", app = APP + "?g=" + g.slug;
  const hi = th ? (g.first ? `สวัสดีคุณ${g.first}` : "สวัสดีครับ") : (g.first ? `Hi ${g.first},` : "Hi,");
  const en: Record<number, [string, string[]]> = {
    1: [`Shall we set up ${g.gym} for you?`, [
      `Thanks for signing up ${g.gym} to Muay Friend. Your app is ready, but it is still empty, and an empty app is hard to picture.`,
      `The quickest way to see what it does is with your own gym in it. Reply to this email with:`,
      `- your class timetable\n- your prices (single class, class packs, monthly)\n- your members (a spreadsheet, or even a photo of your register)`,
      `and we will load it all in for you, free. Then you can check people in and sell packages straight away.`,
      `Or open your app and start yourself: ${app}`]],
    2: [`3 things to get ${g.gym} going in 10 minutes`, [
      `Most gyms are up and running after three small steps. Open your app (${app}) and:`,
      `1. Add your packages: Packages, then Add package (for example 1 class, 10 classes, 1 month).\n2. Add your timetable: Timetable, then Add class. Add each class once and it repeats every week.\n3. Add one member and check them in, to see how it works at the front desk.`,
      `Busy? Just reply with your timetable, prices and member list in any format, and we will do it for you, free.`]],
    3: [`Still want help with ${g.gym}?`, [
      `We noticed your Muay Friend app is still empty, so we wanted to check in once more.`,
      `If now is not the right time, no problem, your app stays ready for you. If you would like help, reply with a good time for a 20 minute video call and we will set it up together, or send us your timetable, prices and members and we will load them in for you.`,
      `Your app: ${app}`]],
  };
  const tl: Record<number, [string, string[]]> = {
    1: [`ให้เราตั้งค่า ${g.gym} ให้ไหม`, [
      `ขอบคุณที่สมัคร ${g.gym} กับ Muay Friend แอปของคุณพร้อมแล้ว แต่ยังว่างอยู่ ซึ่งทำให้นึกภาพการใช้งานได้ยาก`,
      `วิธีที่เร็วที่สุดคือใส่ข้อมูลยิมของคุณเอง ตอบกลับอีเมลนี้พร้อม:`,
      `- ตารางคลาส\n- ราคา (รายครั้ง แพ็กหลายครั้ง รายเดือน)\n- รายชื่อสมาชิก (ไฟล์ Excel หรือรูปถ่ายสมุดรายชื่อก็ได้)`,
      `แล้วเราจะใส่ข้อมูลให้ฟรี จากนั้นคุณเช็คอินและขายแพ็กเกจได้ทันที`,
      `หรือเปิดแอปแล้วเริ่มเองได้เลย: ${app}`]],
    2: [`3 อย่างให้ ${g.gym} เริ่มใช้ได้ใน 10 นาที`, [
      `ยิมส่วนใหญ่เริ่มใช้ได้หลังทำ 3 ขั้นตอนง่ายๆ เปิดแอป (${app}) แล้ว:`,
      `1. เพิ่มแพ็กเกจ: แพ็กเกจ แล้วกด เพิ่มแพ็กเกจ (เช่น 1 ครั้ง 10 ครั้ง 1 เดือน)\n2. เพิ่มตารางคลาส: ตารางเวลา แล้วกด เพิ่มคลาส เพิ่มแต่ละคลาสครั้งเดียว ระบบจะซ้ำทุกสัปดาห์\n3. เพิ่มสมาชิก 1 คนแล้วเช็คอิน เพื่อดูการใช้งานที่เคาน์เตอร์`,
      `ไม่มีเวลา ตอบกลับพร้อมตารางคลาส ราคา และรายชื่อสมาชิกในรูปแบบไหนก็ได้ เราจะทำให้ฟรี`]],
    3: [`ยังต้องการให้ช่วยเรื่อง ${g.gym} ไหม`, [
      `แอป Muay Friend ของคุณยังว่างอยู่ เราเลยอยากถามอีกครั้ง`,
      `ถ้ายังไม่พร้อม ไม่เป็นไร แอปยังพร้อมรอคุณอยู่ ถ้าต้องการให้ช่วย ตอบกลับพร้อมเวลาที่สะดวกสำหรับวิดีโอคอล 20 นาที หรือส่งตารางคลาส ราคา และรายชื่อสมาชิกมา เราจะใส่ให้`,
      `แอปของคุณ: ${app}`]],
  };
  const [subject, lines] = (th ? tl : en)[g.step];
  const sign = th ? "ทีม Muay Friend" : "The Muay Friend team";
  const all = [hi, ...lines];
  const text = all.join("\n\n") + "\n\n" + sign + "\nhttps://muayfriend.com";
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.55;color:#171B23">` +
    all.map((l) => `<p style="margin:0 0 14px">${esc(l).replace(/\n/g, "<br>").replace(esc(app), `<a href="${esc(app)}" style="color:#2F5BD3">${esc(app.replace("https://", ""))}</a>`)}</p>`).join("") +
    `<p style="margin:0">${esc(sign)}<br><a href="https://muayfriend.com" style="color:#2F5BD3">muayfriend.com</a></p></div>`;
  return { subject, text, html };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST.", { status: 405 });
  const key = req.headers.get("x-key") ?? "";
  const { data, error } = await admin.rpc("mf_nudge_list", { p_key: key });
  if (error) return new Response(JSON.stringify({ error: "Not allowed." }), { status: 403 });
  const out: { slug: string; step: number; ok: boolean }[] = [];
  for (const g of (data ?? []) as Gym[]) {
    const m = mail(g);
    const s = await resend({ from: FROM, to: [g.email], reply_to: TEAM, bcc: [TEAM], subject: m.subject, html: m.html, text: m.text });
    await admin.rpc("mf_nudge_mark", { p_key: key, p_slug: g.slug, p_step: g.step, p_result: s.ok ? "sent" : "failed: " + s.err });
    out.push({ slug: g.slug, step: g.step, ok: s.ok });
  }
  return new Response(JSON.stringify({ ok: true, sent: out }), { headers: { "Content-Type": "application/json" } });
});
