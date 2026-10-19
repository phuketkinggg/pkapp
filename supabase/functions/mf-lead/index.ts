// Muay Friend website: "get more info" form. Saves the enquiry and emails it to the owner.
// POST {name, email, gym?, country?, members?, phone?, message?, website (honeypot)}  ->  {ok:true}
// Public (no login). Spam guards: honeypot, field checks, max 5 per hour per visitor, 60 per hour in total.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const TO = "hello@phuketking.com";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, apikey, x-client-info, authorization", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const clip = (x: unknown, n: number) => String(x ?? "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim().slice(0, n);
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function hash(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("mf-lead:" + s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    const b = await req.json().catch(() => ({}));
    if (clip(b.website, 200)) return json({ ok: true }); // bots fill the hidden field
    const name = clip(b.name, 100), email = clip(b.email, 160).toLowerCase();
    if (!name) return json({ error: "Please add your name." }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return json({ error: "Please check your email address." }, 400);
    const row = { name, email, gym: clip(b.gym, 140) || null, country: clip(b.country, 80) || null, members: clip(b.members, 40) || null,
      phone: clip(b.phone, 40) || null, message: clip(b.message, 3000) || null, source: clip(b.source, 120) || null,
      ip_hash: await hash(req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0] ?? "unknown") };
    const hour = new Date(Date.now() - 3600_000).toISOString();
    const [{ count: mine }, { count: all }] = await Promise.all([
      admin.from("mf_leads").select("id", { count: "exact", head: true }).eq("ip_hash", row.ip_hash).gte("created_at", hour),
      admin.from("mf_leads").select("id", { count: "exact", head: true }).gte("created_at", hour)]);
    if ((mine ?? 0) >= 5 || (all ?? 0) >= 60) return json({ error: "Thanks, we already have your message. We will be in touch soon." }, 429);
    const { data: saved, error } = await admin.from("mf_leads").insert(row).select("id").single();
    if (error) return json({ error: "Something went wrong. Please try again." }, 500);

    const key = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
    if (key) {
      const lines: [string, string | null][] = [["Name", row.name], ["Email", row.email], ["Gym", row.gym], ["Country", row.country], ["Members", row.members], ["Phone or WhatsApp", row.phone], ["Message", row.message]];
      const html = `<h2 style="font-family:sans-serif">New Muay Friend enquiry</h2><table style="font-family:sans-serif;font-size:15px">${lines.filter((l) => l[1]).map(([k, v]) => `<tr><td style="padding:4px 14px 4px 0;color:#666;vertical-align:top">${k}</td><td style="padding:4px 0;white-space:pre-wrap">${esc(v!)}</td></tr>`).join("")}</table><p style="font-family:sans-serif;color:#666">Reply to this email to answer them directly.</p>`;
      const text = "New Muay Friend enquiry\n\n" + lines.filter((l) => l[1]).map(([k, v]) => `${k}: ${v}`).join("\n");
      const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: "Muay Friend <hello@app.phuketking.com>", to: [TO], reply_to: row.email, subject: `Muay Friend enquiry: ${row.gym || row.name}`, html, text }) }).catch((e) => ({ ok: false, status: 0, text: () => Promise.resolve(String(e)) } as unknown as Response));
      await admin.from("mf_leads").update({ emailed: r.ok, email_error: r.ok ? null : (await r.text().catch(() => "")).slice(0, 300) || String(r.status) }).eq("id", saved.id);
    } else await admin.from("mf_leads").update({ emailed: false, email_error: "no RESEND_API_KEY" }).eq("id", saved.id);
    return json({ ok: true });
  } catch (_e) { return json({ error: "Something went wrong. Please try again." }, 500); }
});
