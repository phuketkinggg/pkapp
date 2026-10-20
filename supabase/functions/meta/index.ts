// Facebook and Instagram connection for the app (messages inbox to come).
// POST {mode:'check'} with x-sync-token: is META_PAGE_TOKEN working, which page and Instagram, which permissions.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const TOKEN = () => (Deno.env.get("META_PAGE_TOKEN") ?? "").trim();
const G = "https://graph.facebook.com/v23.0";
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function get(path: string, params: Record<string, string> = {}) {
  const r = await fetch(`${G}/${path}?${new URLSearchParams({ ...params, access_token: TOKEN() })}`);
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(j?.error?.message ?? `Meta said ${r.status}`);
  return j;
}

Deno.serve(async (req) => {
  const b = await req.json().catch(() => ({}));
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  if (b.mode !== "check") return json({ error: "Unknown request." }, 400);
  if (!TOKEN()) return json({ ok: false, error: "META_PAGE_TOKEN is not set." });
  const out: Record<string, unknown> = { ok: false };
  try {
    const me = await get("me", { fields: "id,name" });
    out.me = me;
    try {
      const pg = await get(me.id, { fields: "name,instagram_business_account{id,username}" });
      out.page = pg.name; out.instagram = pg.instagram_business_account?.username ?? null; out.ok = true;
    } catch (e) { out.page_error = (e as Error).message; }
    if (!out.ok) {
      // a system user token: find the page through its accounts
      const acc = await get("me/accounts", { fields: "id,name,instagram_business_account{id,username}" });
      out.accounts = (acc.data ?? []).map((a: { id: string; name: string; instagram_business_account?: { username: string } }) => ({ id: a.id, name: a.name, instagram: a.instagram_business_account?.username ?? null }));
      out.ok = (acc.data ?? []).length > 0;
    }
    try {
      const d = await get("debug_token", { input_token: TOKEN() });
      out.type = d.data?.type; out.expires = d.data?.expires_at; out.scopes = d.data?.scopes;
    } catch (e) { out.debug_error = (e as Error).message; }
  } catch (e) { out.error = (e as Error).message; }
  return json(out);
});
