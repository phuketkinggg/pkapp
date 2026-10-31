// Booking emails into the app. The AI reads a confirmation or cancellation email from an agency (Get Your Guide, Viator, Klook...)
// or a booking site (Booking.com, Airbnb) and the database files it (agency_mail_ingest): a group class arrival, a private, or the
// guest's name on a stay. Two ways in:
//   POST {from, subject, text} with header x-mail-token   from the Gmail script (Settings, Booking emails)
//   POST {text} signed in as a manager, admin or the front desk   pasted in the app
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = () => (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
const MODEL = "claude-sonnet-5-5";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-mail-token", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const str = (x: unknown, n: number) => String(x ?? "").slice(0, n);
const today = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);

async function staff(req: Request) {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth) return false;
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data } = await user.auth.getUser();
  if (!data?.user) return false;
  const { data: s } = await admin.from("staff").select("role").eq("user_id", data.user.id).eq("active", true).maybeSingle();
  return ["manager", "admin", "front_desk"].includes(String(s?.role ?? ""));
}

async function read(subject: string, text: string, from: string) {
  const prompt = `This is an email a business received (a gym with group classes and private lessons, a spa, and rooms). Today is ${today()} (Thailand).
From: ${from}
Subject: ${subject}

${text}

If it is a booking confirmation, change or cancellation from an agency or booking site, reply with JSON only:
{"booking": true, "source": "the agency or site, for example Get Your Guide, Viator, Klook, Booking.com, Airbnb", "ref": "their booking reference",
 "kind": "class" (a group class, drop in or tour of classes) | "private" (a private or one to one lesson) | "stay" (a room or accommodation booking) | "other",
 "cancel": true if the booking is cancelled, else false, "name": "the lead guest's full name", "email": "guest email if shown, not the agency's", "phone": "guest phone if shown",
 "people": number of people, "date": "YYYY-MM-DD (the class or private day, or the check in day)", "time": "HH:MM 24 hour if shown",
 "end_date": "YYYY-MM-DD check out day for a stay", "minutes": length in minutes if shown, "product": "the product or option name", "notes": "anything the staff need to know, short"}
If it is not a booking email, reply {"booking": false, "about": "a few words on what it is"}. Never guess dates or names: leave them empty if not shown.`;
  const slot = await admin.rpc("ai_usage_take", { p_fn: "booking-mail" });
  if (slot.error || !slot.data) throw new Error("This month's AI allowance is used up.");
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", headers: { "x-api-key": KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 700, messages: [{ role: "user", content: prompt }] }),
  });
  const j = await res.json().catch(() => ({}));
  await admin.from("ai_usage").update({ in_tokens: j?.usage?.input_tokens ?? null, out_tokens: j?.usage?.output_tokens ?? null, ok: res.ok }).eq("id", slot.data);
  if (!res.ok) throw new Error("The AI said: " + (j?.error?.message ?? res.status));
  const out = String((j.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join(""));
  return JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  const token = req.headers.get("x-mail-token") ?? "";
  let via = "";
  if (token) { const { data: ok } = await admin.rpc("mail_token_ok", { p_token: token }); if (ok === true) via = "gmail"; }
  if (!via && await staff(req)) via = "pasted";
  if (!via) return json({ error: "Not allowed." }, 401);
  const subject = str(b.subject, 300), from = str(b.from, 200), text = str(b.text, 40000).replace(/\n{3,}/g, "\n\n");
  if (text.trim().length < 20) return json({ error: "Paste the whole email." });
  const { data: mid } = await admin.rpc("inbound_mail_save", { p: { via, from, subject, text } });
  // Gmail asks to confirm forwarding first: kept, and shown in Settings with its link
  if (/forwarding confirmation|confirm.*forward/i.test(subject)) {
    await admin.rpc("inbound_mail_done", { p_id: mid, p_status: "confirm", p_result: "Gmail forwarding check. Open the link in Settings, Booking emails, to confirm." });
    return json({ ok: true, what: "Gmail forwarding check kept." });
  }
  if (!KEY()) { await admin.rpc("inbound_mail_done", { p_id: mid, p_status: "error", p_result: "The AI is not set up yet." }); return json({ error: "The AI is not set up yet." }); }
  try {
    const o = await read(subject, text, from);
    if (!o?.booking) {
      await admin.rpc("inbound_mail_done", { p_id: mid, p_status: "skipped", p_result: "Not a booking: " + str(o?.about, 200) });
      return json({ ok: true, what: "Not a booking email: " + str(o?.about, 200) });
    }
    const { data, error } = await admin.rpc("agency_mail_ingest", { p: o, p_mail: mid });
    if (error) throw new Error(error.message);
    const r = data as { ok: boolean; booking?: string; what: string };
    await admin.rpc("inbound_mail_done", { p_id: mid, p_status: r.ok ? "done" : "error", p_result: r.what, p_booking: r.booking ?? null });
    return json({ ok: r.ok, what: r.what, read: o });
  } catch (e) {
    await admin.rpc("inbound_mail_done", { p_id: mid, p_status: "error", p_result: (e as Error).message });
    return json({ error: (e as Error).message });
  }
});
