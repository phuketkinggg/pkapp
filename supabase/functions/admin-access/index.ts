// A manager gives a staff member or customer app access: their login is made already verified,
// with a starting password shown once to the manager. They must choose their own password on first sign in.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// easy to read aloud: no 0/O, 1/l/I
function startPassword(): string {
  const chars = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
  const a = new Uint32Array(10); crypto.getRandomValues(a);
  return Array.from(a, (n) => chars[n % chars.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(jwt);
    if (!u?.user) return json({ error: "Sign in first." }, 401);
    const { data: me } = await admin.from("staff").select("id,role,active").eq("user_id", u.user.id).maybeSingle();
    if (!me || !me.active || me.role !== "manager") return json({ error: "Only a manager can give app access." }, 403);

    const body = await req.json().catch(() => ({}));
    const kind = body.kind === "staff" ? "staff" : body.kind === "customer" ? "customers" : null;
    if (!kind || !body.id) return json({ error: "Choose who to give access to." }, 400);
    const { data: row } = await admin.from(kind).select("id,name,email,user_id").eq("id", body.id).maybeSingle();
    if (!row) return json({ error: "Not found." }, 404);
    const email = String(row.email ?? "").trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "Add their email first, then give access." }, 400);
    if (kind === "staff" && u.user.id === row.user_id) return json({ error: "Use the Password button to change your own password." }, 400);

    const password = startPassword();
    const meta = { must_change_password: true, name: row.name };
    const { data: found } = await admin.rpc("admin_auth_lookup", { p_email: email });
    let uid: string;
    if (!found) {
      const { data: made, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: meta });
      if (error) return json({ error: error.message }, 400);
      uid = made.user!.id;
    } else {
      // a customer already using the app keeps their own password; they can use Forgot password
      if (kind === "customers" && found.signed_in) return json({ error: `${row.name} already uses the app. If they forgot their password, they tap Forgot password on the sign in screen.` }, 409);
      const { error } = await admin.auth.admin.updateUserById(found.id, { password, email_confirm: true, user_metadata: meta });
      if (error) return json({ error: error.message }, 400);
      uid = found.id;
    }
    // link the login to this person straight away
    if (row.user_id !== uid) {
      const { error } = await admin.from(kind).update({ user_id: uid }).eq("id", row.id);
      if (error && !/duplicate|unique/i.test(error.message)) return json({ error: error.message }, 400);
    }
    return json({ ok: true, email, password, name: row.name, existing: !!found });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
