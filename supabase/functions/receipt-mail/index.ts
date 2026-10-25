// A receipt by email, sent from the app by the desk (a package, a private or a till sale).
// POST {token, to, link}  signed-in desk staff: emails the receipt with a button to the receipt page.
// The sender and reply address come from Settings, Welcome email (from, reply to). Secret: RESEND_API_KEY.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const thb = (n: unknown) => Math.round(Number(n) || 0).toLocaleString("en-US") + " THB";
const PAY: Record<string, string> = { cash: "Cash", qr: "PromptPay QR", card: "Card", transfer: "Bank transfer", stripe: "Card (online)", room: "Room bill", pack: "From a pack", staff: "Staff" };

type Line = { name: string; amount: number };
type R = { business: string; address?: string; tax_id?: string; footer: string; email?: string; accent?: string; number: string; date: string; customer?: string;
  lines: Line[]; discount: number; fee: number; tax: number; total: number; paid: number; owed: number; payments: { amount: number; method: string; day: string }[]; refunded: boolean; room: boolean };

function html(r: R, link: string) {
  const a = /^#[0-9a-f]{6}$/i.test(r.accent ?? "") ? r.accent! : "#171B23";
  const row = (k: string, v: string, b = false) => `<tr><td style="padding:6px 0;${b ? "font-weight:700;" : ""}">${k}</td><td style="padding:6px 0;text-align:right;${b ? "font-weight:700;" : ""}">${v}</td></tr>`;
  const day = new Date(r.date + "T00:00:00Z").toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>` +
    `<body style="margin:0;padding:16px;background:#f4f4f2;font-family:Arial,Helvetica,sans-serif;color:#171B23">` +
    `<div style="max-width:480px;margin:0 auto;background:#fff;border-radius:10px;padding:24px;border-top:5px solid ${a}">` +
    `<p style="margin:0;font-size:20px;font-weight:700">${esc(r.business)}</p>` +
    (r.address ? `<p style="margin:4px 0 0;font-size:13px;color:#666">${esc(r.address)}</p>` : "") +
    (r.tax_id ? `<p style="margin:2px 0 0;font-size:13px;color:#666">Tax ID ${esc(r.tax_id)}</p>` : "") +
    `<p style="margin:18px 0 2px;font-size:13px;color:#666">Receipt ${esc(r.number)}, ${esc(day)}</p>` +
    (r.customer ? `<p style="margin:0 0 12px;font-size:15px">For ${esc(r.customer)}</p>` : "") +
    `<table style="width:100%;border-collapse:collapse;font-size:15px;border-top:1px solid #eee;margin-top:8px">` +
    r.lines.map((l) => row(esc(l.name), thb(l.amount))).join("") +
    (r.discount ? row("Discount", "-" + thb(r.discount)) : "") + (r.fee ? row("Card fee", thb(r.fee)) : "") + (r.tax ? row("Tax", thb(r.tax)) : "") +
    `<tr><td colspan="2" style="border-top:1px solid #eee"></td></tr>` + row("Total", thb(r.total), true) +
    r.payments.map((p) => row("Paid, " + esc(PAY[p.method] ?? p.method ?? ""), thb(p.amount))).join("") +
    (r.owed ? row("Still to pay", thb(r.owed), true) : "") + `</table>` +
    (r.room ? `<p style="font-size:14px">Added to your room bill.</p>` : "") + (r.refunded ? `<p style="font-size:14px;color:#B8001A">Refunded.</p>` : "") +
    `<p style="margin:20px 0"><a href="${esc(link)}" style="display:inline-block;background:${a};color:#fff;text-decoration:none;padding:12px 18px;border-radius:8px;font-weight:700">View or save the receipt</a></p>` +
    `<p style="margin:0;font-size:14px">${esc(r.footer)}</p></div></body></html>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (!RESEND) return json({ error: "Email sending is not set up yet. Add RESEND_API_KEY in Supabase." });
  const b = await req.json().catch(() => ({}));
  const token = String(b.token ?? ""), to = String(b.to ?? "").trim().toLowerCase(), link = String(b.link ?? "");
  if (!/^[0-9a-f]{24,64}$/.test(token)) return json({ error: "No receipt." });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return json({ error: "Type a real email address." });
  if (!/^https:\/\/[^\s]+$/.test(link) || !link.includes(token)) return json({ error: "Bad receipt link." });
  // the desk only: the database checks the signed-in person and notes the email
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const { error: se } = await user.rpc("receipt_sent", { p_token: token, p_how: "email", p_to: to });
  if (se) return json({ error: se.message });
  const { data: r } = await admin.rpc("receipt_view", { p_token: token });
  if (!r) return json({ error: "Receipt not found." });
  const rr = r as R;
  let we: Record<string, string> = {};
  try { const { data } = await admin.from("app_settings").select("value").eq("key", "welcome_email").maybeSingle(); we = JSON.parse(data?.value ?? "{}"); } catch { /* defaults */ }
  if (!(we.from || "").includes("@")) return json({ error: "Set who emails come from first: Settings, Welcome email, From." });
  const from = we.from;
  const text = `${rr.business}\nReceipt ${rr.number}\nTotal ${thb(rr.total)}${rr.owed ? `, still to pay ${thb(rr.owed)}` : ""}\n\nView or save the receipt: ${link}\n\n${rr.footer}`;
  const res = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [to], reply_to: we.reply_to || rr.email || undefined, subject: `Your receipt from ${rr.business}`, html: html(rr, link), text }) });
  const j = await res.json().catch(() => ({}));
  return res.ok ? json({ ok: true }) : json({ error: "Not sent: " + ((j as { message?: string }).message ?? res.status) });
});
