// Uptime alert: the app's watchdog (a job in another database) calls this when the app stops answering, and again when it is back.
// It only ever sends one fixed email to the business (ALERT_TO, else the reply-to address), and at most one of each kind every 30 minutes,
// so it needs no database (it has to work when the database side is down).
const RESEND = () => (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const TO = () => (Deno.env.get("ALERT_TO") ?? "").trim() || "hello@phuketking.com";
const FROM = () => (Deno.env.get("ALERT_FROM") ?? "").trim() || "App watchdog <hello@app.phuketking.com>";
const last: Record<string, number> = {};

Deno.serve(async (req) => {
  const b = await req.json().catch(() => ({}));
  const what = b.what === "up" ? "up" : "down";
  const detail = String(b.detail ?? "").replace(/[<>]/g, "").slice(0, 300);
  if (Date.now() - (last[what] ?? 0) < 30 * 60e3) return new Response(JSON.stringify({ ok: true, skipped: true }), { headers: { "Content-Type": "application/json" } });
  last[what] = Date.now();
  const subject = what === "down" ? "The app is not answering" : "The app is working again";
  const text = what === "down"
    ? `The app's server stopped answering (checked every 5 minutes, failed twice in a row).\n\n${detail}\n\nWhat to do: open supabase.com/dashboard, open the project, Project Settings, General, Restart project. It takes about 2 minutes. You get another email when it is working again.`
    : `The app is answering normally again.\n\n${detail}`;
  if (!RESEND()) return new Response(JSON.stringify({ error: "no email key" }), { status: 500 });
  const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND()}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM(), to: [TO()], subject, text }) });
  return new Response(JSON.stringify({ ok: r.ok, status: r.status }), { headers: { "Content-Type": "application/json" } });
});
