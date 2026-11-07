// The owner is locked out: their email, one of their recovery codes and a new password (Settings, General, Owner, Recovery codes).
// The database checks the code (5 wrong tries an hour, 15 a day) and uses it up; then the new password is set here and the owner is
// put back as an active manager. An email tells the owner it happened. No sign in needed, so nothing here trusts the caller.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    const b = await req.json().catch(() => ({}));
    const email = String(b.email ?? "").trim().slice(0, 120), code = String(b.code ?? "").slice(0, 40), pw = String(b.password ?? "");
    if (!email || !code) return json({ error: "Type your email and a recovery code." });
    if (pw.length < 10 || pw.length > 72) return json({ error: "Choose a new password of at least 10 characters." });
    const { data: uid, error } = await admin.rpc("owner_recover_check", { p_email: email, p_code: code });
    if (error) return json({ error: error.message });
    if (!uid) return json({ error: "That email and code do not match." });
    const up = await admin.auth.admin.updateUserById(String(uid), { password: pw });
    if (up.error) return json({ error: "The code worked, but the new password was not saved: " + up.error.message + " Use another code." });
    // tell the owner, in case it was not them
    await admin.from("sent_emails").insert({ to_email: email.toLowerCase(), subject: "Your account was recovered with a recovery code",
      body: "Someone used one of your recovery codes to set a new password on your owner account just now.\n\nIf this was you, you can sign in with your new password. Make a new set of recovery codes in Settings, General, Owner, because each code works once.\n\nIf this was not you, sign in straight away with Forgot password, and make new recovery codes.",
      status: "queued", campaign: "owner_recover", send_after: new Date().toISOString() });
    return json({ ok: true });
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
