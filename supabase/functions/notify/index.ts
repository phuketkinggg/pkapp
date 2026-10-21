// Emails the office about a new booking. Called by the database (x-sync-token), see supabase/sql/booking_email.sql.
// POST {kind:'stay'|'webpkg', id}
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

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  const b = await req.json().catch(() => ({}));
  const kind = String(b.kind ?? ""), id = String(b.id ?? "");
  if (!["stay", "webpkg"].includes(kind) || !/^[0-9a-f-]{36}$/.test(id)) return json({ error: "Bad request." }, 400);
  const { data: d, error } = await admin.rpc("booking_mail_data", { p_kind: kind, p_id: id });
  if (error || !d) return json({ error: error?.message ?? "Not found." }, 404);

  let subject: string, body: { html: string; text: string };
  if (kind === "stay") {
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
      ["Paid by", d.method ?? ""], ["Starts", d.course ? "Online course, unlocked in their app" : d.start ? day(d.start) : "At their first class"], ["Note", d.note ?? ""]]);
  }

  const key = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
  let err: string | null = null;
  if (!key) err = "no RESEND_API_KEY";
  else {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: "Phuket King bookings <hello@app.phuketking.com>", to: [d.to_email], reply_to: d.email || undefined, subject, html: body.html, text: body.text }) })
      .catch((e) => ({ ok: false, status: 0, text: () => Promise.resolve(String(e)) } as unknown as Response));
    if (!r.ok) err = `Resend ${r.status}: ${(await r.text()).slice(0, 300)}`;
  }
  await admin.rpc("booking_mail_done", { p_kind: kind, p_id: id, p_error: err });
  return json(err ? { error: err } : { ok: true });
});
