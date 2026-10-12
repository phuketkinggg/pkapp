// Welcome email for a stay: welcome, room, dates, receipt, useful info and extras to add.
// preview: returns the email so the desk can look at it first. send: sends it. auto: the database job sends it to new bookings.
import { createClient } from "npm:@supabase/supabase-js@2";

const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const APP = "https://phuketkinggg.github.io/pkapp/";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

type Line = { what: string; amount: number | null; note?: string };
type Item = { title?: string; text?: string; price?: string; link?: string; off?: boolean };
type Data = {
  stay_id: string; guest: string | null; email: string | null; room: string | null; source: string | null;
  check_in: string; check_out: string; nights: number; training: boolean; lines: Line[]; total: number; paid: number; owed: number;
  settings: { from?: string; reply_to?: string; subject?: string; intro?: string; info?: Item[]; upsells?: Item[]; whatsapp?: string; footer?: string; auto?: boolean; auto_sources?: string; auto_since?: string | null };
};

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const thb = (n: number) => Math.round(n).toLocaleString("en-US") + " THB";
const day = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const first = (n: string | null) => String(n ?? "").trim().split(/\s+/)[0] || "there";
const okEmail = (e: unknown) => /^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/.test(String(e ?? ""));
const nl = (s: string) => esc(s).replace(/\n/g, "<br>");

function waLink(num: string, text: string) { return `https://wa.me/${num.replace(/\D/g, "")}?text=${encodeURIComponent(text)}`; }

function render(d: Data) {
  const s = d.settings || {};
  const wa = s.whatsapp || "66969076150";
  const subject = s.subject || "Welcome to Phuket King";
  const G = "#1a3325", C = "#f5f0e8", GOLD = "#c9a84c", INK = "#22201c", MUT = "#6b665c";
  const when = `${day(d.check_in)} to ${day(d.check_out)}, ${d.nights} night${d.nights === 1 ? "" : "s"}`;
  const rows = d.lines.map((l) => `<tr><td style="padding:8px 0;border-bottom:1px solid #e6dfd2;color:${INK}">${esc(l.what)}</td><td align="right" style="padding:8px 0;border-bottom:1px solid #e6dfd2;color:${INK};white-space:nowrap">${l.amount == null ? esc(l.note || "") : thb(l.amount)}</td></tr>`).join("");
  const money = d.total > 0 ? `
      <tr><td style="padding:8px 0;font-weight:bold">Total</td><td align="right" style="padding:8px 0;font-weight:bold">${thb(d.total)}</td></tr>
      ${d.paid > 0 ? `<tr><td style="padding:4px 0;color:${MUT}">Paid</td><td align="right" style="padding:4px 0;color:${MUT}">${thb(d.paid)}</td></tr>` : ""}
      <tr><td style="padding:4px 0;font-weight:bold;color:${d.owed > 0 ? "#9a3b1b" : G}">${d.owed > 0 ? "Still to pay" : "Paid in full"}</td><td align="right" style="padding:4px 0;font-weight:bold;color:${d.owed > 0 ? "#9a3b1b" : G}">${d.owed > 0 ? thb(d.owed) : ""}</td></tr>` : "";
  const payNote = d.owed > 0 ? `<p style="margin:12px 0 0;color:${MUT};font-size:14px">You can pay at the desk by cash, card or PromptPay, or in the Phuket King app.</p>` : "";
  const info = (s.info || []).filter((i) => !i.off && (i.title || i.text)).map((i) => `
      <tr><td style="padding:0 0 16px">
        <div style="font-weight:bold;color:${G};font-size:16px;margin:0 0 4px">${esc(i.title)}</div>
        <div style="color:${INK};font-size:15px;line-height:1.5">${nl(i.text || "")}</div>
      </td></tr>`).join("");
  const ups = (s.upsells || []).filter((u) => !u.off && u.title).map((u) => {
    const link = u.link && /^https?:\/\//.test(u.link) ? u.link : waLink(wa, `Hi, I'd like to add ${u.title} to my stay (${d.room || "room"}, ${d.check_in} to ${d.check_out}). ${d.guest || ""}`.trim());
    return `
      <tr><td style="padding:0 0 12px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#ffffff;border:1px solid #e6dfd2;border-radius:10px">
          <tr><td style="padding:14px 16px">
            <div style="font-weight:bold;color:${G};font-size:16px">${esc(u.title)}${u.price ? ` <span style="color:${GOLD};font-weight:bold;font-size:14px">&nbsp;${esc(u.price)}</span>` : ""}</div>
            ${u.text ? `<div style="color:${INK};font-size:14px;line-height:1.5;margin:4px 0 10px">${nl(u.text)}</div>` : `<div style="height:8px"></div>`}
            <a href="${esc(link)}" style="display:inline-block;background:${G};color:#ffffff;text-decoration:none;font-size:14px;font-weight:bold;padding:9px 16px;border-radius:8px">Add to my stay</a>
          </td></tr>
        </table>
      </td></tr>`;
  }).join("");
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:${C};font-family:Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${C}"><tr><td align="center" style="padding:20px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px">
  <tr><td style="background:${G};border-radius:12px 12px 0 0;padding:28px 24px;color:#ffffff">
    <div style="color:${GOLD};font-size:13px;letter-spacing:2px;text-transform:uppercase;font-weight:bold">Phuket King &middot; Pangea Resort</div>
    <div style="font-size:26px;font-weight:bold;margin:8px 0 0">Welcome, ${esc(first(d.guest))}!</div>
  </td></tr>
  <tr><td style="background:#fbf8f2;padding:24px;border-radius:0 0 12px 12px">
    <p style="margin:0 0 20px;color:${INK};font-size:16px;line-height:1.5">${nl(s.intro || "")}</p>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#ffffff;border:1px solid #e6dfd2;border-radius:10px;margin:0 0 24px"><tr><td style="padding:16px">
      <div style="color:${MUT};font-size:13px;text-transform:uppercase;letter-spacing:1px">Your room</div>
      <div style="color:${G};font-size:22px;font-weight:bold;margin:2px 0 6px">${esc(d.room || "We will confirm your room on arrival")}</div>
      <div style="color:${INK};font-size:15px">${esc(when)}</div>
    </td></tr></table>
    <div style="color:${G};font-size:18px;font-weight:bold;margin:0 0 6px">Your receipt</div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:15px;margin:0 0 4px">${rows}${money}</table>
    ${payNote}
    <div style="height:24px"></div>
    <div style="color:${G};font-size:18px;font-weight:bold;margin:0 0 12px">Good to know</div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">${info}</table>
    ${ups ? `<div style="color:${G};font-size:18px;font-weight:bold;margin:8px 0 12px">Make the most of your stay</div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">${ups}</table>` : ""}
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:16px 0 0"><tr>
      <td style="padding:0 8px 8px 0"><a href="${APP}" style="display:inline-block;background:${GOLD};color:${G};text-decoration:none;font-weight:bold;font-size:14px;padding:10px 16px;border-radius:8px">Open the Phuket King app</a></td>
      <td style="padding:0 0 8px 0"><a href="${esc(waLink(wa, `Hi, it's ${d.guest || "a guest"}, booked in ${d.room || "a room"} from ${d.check_in}.`))}" style="display:inline-block;border:2px solid ${G};color:${G};text-decoration:none;font-weight:bold;font-size:14px;padding:8px 14px;border-radius:8px">WhatsApp us</a></td>
    </tr></table>
    <p style="margin:20px 0 0;color:${MUT};font-size:14px;line-height:1.5">${nl(s.footer || "")}</p>
  </td></tr>
</table></td></tr></table></body></html>`;
  const text = [
    `Welcome, ${first(d.guest)}!`, "", s.intro || "", "",
    `Your room: ${d.room || "we will confirm on arrival"}`, when, "",
    "Your receipt:", ...d.lines.map((l) => `- ${l.what}: ${l.amount == null ? l.note || "" : thb(l.amount)}`),
    d.total > 0 ? `Total ${thb(d.total)}${d.paid > 0 ? `, paid ${thb(d.paid)}` : ""}${d.owed > 0 ? `, still to pay ${thb(d.owed)}` : ", paid in full"}` : "", "",
    ...(s.info || []).filter((i) => !i.off && (i.title || i.text)).flatMap((i) => [i.title || "", i.text || "", ""]),
    ...(s.upsells || []).filter((u) => !u.off && u.title).map((u) => `Add ${u.title}${u.price ? ` (${u.price})` : ""}: WhatsApp +${wa.replace(/\D/g, "")}`),
    "", `App: ${APP}`, s.footer || "",
  ].join("\n");
  return { subject, html, text };
}

async function send(d: Data, to: string, by: string | null, auto: boolean) {
  const s = d.settings || {};
  const m = render(d);
  let ok = false, err: string | null = null, pid: string | null = null;
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: s.from || "Phuket King <hello@phuketking.com>", to: [to], reply_to: s.reply_to || undefined, subject: m.subject, html: m.html, text: m.text }),
    });
    const j = await r.json().catch(() => ({}));
    if (r.ok) { ok = true; pid = j?.id ?? null; } else err = j?.message || `Email service said ${r.status}`;
  } catch (e) { err = (e as Error).message; }
  await admin.from("stay_emails").insert({ stay_id: d.stay_id, to_email: to, sent_by: by, auto, ok, error: err, provider_id: pid });
  if (ok) await admin.from("stays").update({ welcome_sent_at: new Date().toISOString() }).eq("id", d.stay_id);
  return { ok, error: err };
}

const OTA = /booking|airbnb|agoda|expedia|trip\.com|hotels/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const body = await req.json().catch(() => ({}));
  try {
    if (body.mode === "auto") {
      const { data: tok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
      if (tok !== true) return json({ error: "Not allowed." }, 401);
      if (!RESEND) return json({ ok: true, skipped: "no email key" });
      const { data: row } = await admin.from("app_settings").select("value").eq("key", "welcome_email").maybeSingle();
      let cfg: Data["settings"] = {};
      try { cfg = JSON.parse(row?.value ?? "{}"); } catch { /* keep empty */ }
      if (!cfg.auto || !cfg.auto_since) return json({ ok: true, skipped: "automatic emails are off" });
      const today = new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
      const { data: list } = await admin.from("stays").select("id").is("welcome_sent_at", null).in("status", ["booked", "in"])
        .gte("check_out", today).gte("created_at", cfg.auto_since).order("created_at").limit(15);
      let sent = 0; const skipped: string[] = [];
      for (const st of list ?? []) {
        const { count } = await admin.from("stay_emails").select("id", { count: "exact", head: true }).eq("stay_id", st.id).eq("ok", false);
        if ((count ?? 0) >= 3) continue;
        const { data: d, error } = await admin.rpc("stay_email_data", { p_stay: st.id });
        if (error || !d) continue;
        if (!okEmail(d.email)) { skipped.push(st.id); continue; }
        if (cfg.auto_sources !== "all" && d.source && OTA.test(d.source)) continue;
        const r = await send(d as Data, String(d.email).toLowerCase(), null, true);
        if (r.ok) sent++;
      }
      return json({ ok: true, sent, no_email: skipped.length });
    }

    const auth = req.headers.get("authorization") ?? "";
    const user = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: d, error } = await user.rpc("stay_email_data", { p_stay: String(body.stay_id ?? "") });
    if (error) return json({ error: error.message === "Not allowed" ? "Only the desk and managers can send this." : error.message });
    const data = d as Data;
    if (body.mode === "preview") {
      const m = render(data);
      return json({ ...m, to: data.email, sent_at: (d as { sent_at?: string }).sent_at ?? null, can_send: !!RESEND });
    }
    if (body.mode === "send") {
      if (!RESEND) return json({ error: "Email sending is not set up yet. Add RESEND_API_KEY in Supabase, then try again." });
      const to = String(body.to ?? data.email ?? "").trim().toLowerCase();
      if (!okEmail(to)) return json({ error: "Type a valid email address." });
      const { data: u } = await user.auth.getUser();
      const r = await send(data, to, u?.user?.id ?? null, false);
      return r.ok ? json({ ok: true, to }) : json({ error: `The email did not go: ${r.error}` });
    }
    return json({ error: "Unknown mode." });
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
