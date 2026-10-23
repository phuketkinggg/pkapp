// Emails the office about a new booking, and customers about their private. Called by the database (x-sync-token), see supabase/sql/booking_email.sql and private_booking.sql.
// POST {kind:'stay'|'webpkg'|'private_ok'|'private_no', id}
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const APP = "https://app.phuketking.com/";
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const thb = (n: unknown) => n == null || n === "" ? "" : Number(n).toLocaleString("en-US") + " THB";
const day = (d: unknown) => d ? new Date(String(d).slice(0, 10) + "T00:00:00Z").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }) : "";

type Row = [string, string];
function mail(title: string, intro: string, rows: Row[], extra = "") {
  const tr = rows.filter((r) => r[1]).map(([k, v]) =>
    `<tr><td style="padding:8px 12px;border-bottom:1px solid #e5e5e0;color:#666;width:150px;vertical-align:top">${esc(k)}</td><td style="padding:8px 12px;border-bottom:1px solid #e5e5e0;font-weight:600">${esc(v).replace(/\n/g, "<br>")}</td></tr>`).join("");
  const html = `<div style="font-family:Arial,sans-serif;max-width:620px;margin:0 auto;color:#141414">
<h2 style="margin:0 0 6px;font-size:22px">${esc(title)}</h2><p style="margin:0 0 16px;color:#444">${esc(intro)}</p>
<table style="border-collapse:collapse;width:100%;font-size:14px;border:1px solid #e5e5e0">${tr}</table>${extra}
<p style="margin:20px 0 0"><a href="${APP}" style="background:#141414;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none;font-weight:600">Open the app</a></p>
<p style="color:#888;font-size:12px;margin-top:18px">Sent by the Phuket King app for each new booking.</p></div>`;
  const text = `${title}\n${intro}\n\n` + rows.filter((r) => r[1]).map(([k, v]) => `${k}: ${v}`).join("\n") + `\n\nOpen the app: ${APP}`;
  return { html, text };
}

// emails to a customer about their private (confirmed, or not possible with other times offered)
function custMail(title: string, paras: string[]) {
  const html = `<div style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;color:#141414">
<h2 style="margin:0 0 12px;font-size:22px">${esc(title)}</h2>${paras.map((p) => `<p style="margin:0 0 12px;line-height:1.5">${esc(p).replace(/\n/g, "<br>")}</p>`).join("")}
<p style="margin:20px 0 0"><a href="${APP}" style="background:#141414;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none;font-weight:600">Open the Phuket King app</a></p>
<p style="color:#888;font-size:12px;margin-top:18px">Phuket King Muay Thai, Kathu, Phuket. Reply to this email or WhatsApp us with any questions.</p></div>`;
  return { html, text: `${title}\n\n${paras.join("\n\n")}\n\nOpen the app: ${APP}` };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  const b = await req.json().catch(() => ({}));
  const kind = String(b.kind ?? ""), id = String(b.id ?? "");
  if (!["stay", "webpkg", "private_ok", "private_no"].includes(kind) || !/^[0-9a-f-]{36}$/.test(id)) return json({ error: "Bad request." }, 400);
  const { data: d, error } = await admin.rpc("booking_mail_data", { p_kind: kind, p_id: id });
  if (error || !d) return json({ error: error?.message ?? "Not found." }, 404);

  let subject: string, body: { html: string; text: string }, from = "Phuket King bookings <hello@app.phuketking.com>", reply: string | undefined = d.email || undefined;
  if (kind === "private_ok" || kind === "private_no") {
    from = "Phuket King Muay Thai <hello@app.phuketking.com>"; reply = "hello@phuketking.com";
    const first = String(d.guest ?? "").split(" ")[0] || "there";
    if (kind === "private_ok") {
      subject = `Your private is confirmed: ${day(d.date)} at ${d.time}`;
      body = custMail("Your private is confirmed", [`Hi ${first},`, `Your private lesson is booked for ${day(d.date)}, ${d.time} to ${d.until}${d.coach ? `, with ${d.coach}` : ""}.`,
        "Please arrive 10 minutes early to warm up, and bring hand wraps and gloves if you have them. If you need to change the time, reply to this email or WhatsApp us.", "See you on the mats!"]);
    } else {
      const offers = (d.offers ?? []).map((o: { date: string; time: string; coach: string }) => `${day(o.date)} at ${o.time}${o.coach ? ` with ${o.coach}` : ""}`);
      subject = "About your private request";
      body = custMail("We could not confirm your private", [`Hi ${first},`, `Sorry, we could not confirm your private on ${day(d.date)} at ${d.time}.${d.reason ? ` ${d.reason}` : ""}`,
        offers.length ? `We can offer:\n${offers.join("\n")}\n\nPick one in the Phuket King app (sign in with this email), or reply to this email.` : "Reply to this email or WhatsApp us and we will find another time. Your pack is not used."]);
    }
  } else if (kind === "stay") {
    const owe = Math.max(0, Number(d.price ?? 0) + (d.extras ?? []).reduce((t: number, x: { price: number }) => t + Number(x.price || 0), 0) - Number(d.paid ?? 0)
      - (d.extras ?? []).reduce((t: number, x: { paid: number }) => t + Number(x.paid || 0), 0));
    const extras = (d.extras ?? []).map((x: { name: string; price: number }) => `${x.name}, ${thb(x.price)}`).join("\n");
    subject = `New booking: ${d.guest ?? "Guest"}, ${d.room ?? "room"}, ${day(d.from)} to ${day(d.to)}`;
    body = mail("New room booking", `${d.guest ?? "A guest"} booked ${d.room ?? "a room"} for ${d.nights} night${d.nights === 1 ? "" : "s"}.`, [
      ["Guest", d.guest ?? ""], ["Email", d.email ?? ""], ["Phone", d.phone ?? ""],
      ["Room", d.room ?? ""], ["Arrives", day(d.from)], ["Leaves", day(d.to)], ["Nights", String(d.nights ?? "")], ["Guests", d.guests ?? ""],
      ["Booked through", d.source ?? ""], ["Room price", thb(d.price)], ["Extras", extras],
      ["Paid so far", thb(d.paid)], ["Still to pay", owe ? thb(owe) : "Nothing"],
      ["Group Muay Thai", d.training === false ? "Not included" : "Included for 1 person"],
      ["Referred by", d.affiliate ?? ""], ["Notes", d.notes ?? ""]]);
  } else {
    subject = `New website order: ${d.what}, ${d.guest}`;
    body = mail("New website order", `${d.guest} bought ${d.what} on the website.`, [
      ["Name", d.guest ?? ""], ["Email", d.email ?? ""], ["Phone", d.phone ?? ""], ["Bought", d.what ?? ""], ["Amount", thb(d.price)],
      ["Paid by", d.method ?? ""], ["Private booked", d.private ? d.private + " Confirm it in the app." : ""], ["Starts", d.course ? "Online course, unlocked in their app" : d.start ? day(d.start) : "At their first class"], ["Note", d.note ?? ""]]);
  }

  const key = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
  let err: string | null = null;
  if (!key) err = "no RESEND_API_KEY";
  else {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [d.to_email], reply_to: reply, subject, html: body.html, text: body.text }) })
      .catch((e) => ({ ok: false, status: 0, text: () => Promise.resolve(String(e)) } as unknown as Response));
    if (!r.ok) err = `Resend ${r.status}: ${(await r.text()).slice(0, 300)}`;
  }
  await admin.rpc("booking_mail_done", { p_kind: kind, p_id: id, p_error: err });
  return json(err ? { error: err } : { ok: true });
});
