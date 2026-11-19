// Apple In-App Purchase for courses in the iPhone and iPad app (feature ios_iap).
// POST {jws} with the person's sign in (Authorization: Bearer <access token>): the app sends the StoreKit 2 transaction after a purchase
// or a restore. Apple's signature is checked here (verify.ts), then iap_apple_grant records the purchase and unlocks the course.
// POST {signedPayload} with no sign in: App Store Server Notifications V2 (set this function's address in App Store Connect,
// App Information, App Store Server Notifications). A refund or revoke takes the course away again.
// APPLE_BUNDLE_IDS (optional): the apps allowed, comma separated. Default: the Phuket King app.
import { createClient } from "npm:@supabase/supabase-js@2";
import { verifyAppleJws } from "./verify.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const BUNDLES = (Deno.env.get("APPLE_BUNDLE_IDS") ?? "com.phuketking.app").split(",").map((s) => s.trim()).filter(Boolean);
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const out = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

function pick(t: Record<string, unknown>) {
  return { productId: t.productId, transactionId: String(t.transactionId ?? ""), originalTransactionId: String(t.originalTransactionId ?? t.transactionId ?? ""),
    appAccountToken: t.appAccountToken ?? null, environment: t.environment ?? null, price: t.price != null ? String(t.price) : null, currency: t.currency ?? null };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  try {
    // App Store Server Notifications V2: refunds and revokes
    if (b.signedPayload) {
      const n = await verifyAppleJws(String(b.signedPayload));
      const data = (n.data ?? {}) as Record<string, unknown>;
      if (data.bundleId && !BUNDLES.includes(String(data.bundleId))) return out({ ok: true, skipped: "other app" });
      const type = String(n.notificationType ?? "");
      if ((type === "REFUND" || type === "REVOKE") && data.signedTransactionInfo) {
        const t = await verifyAppleJws(String(data.signedTransactionInfo));
        const { error } = await admin.rpc("iap_apple_revoke", { p: pick(t) });
        if (error) throw new Error(error.message);
      }
      return out({ ok: true });
    }
    // a purchase or restore from the app
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(token);
    if (!u?.user) return out({ error: "Sign in to your account first." }, 401);
    const t = await verifyAppleJws(String(b.jws ?? ""));
    if (!BUNDLES.includes(String(t.bundleId))) throw new Error("This purchase is from another app.");
    if (t.type && t.type !== "Non-Consumable") throw new Error("This kind of purchase is not used for courses.");
    if (t.revocationDate) throw new Error("Apple refunded this purchase.");
    const { data, error } = await admin.rpc("iap_apple_grant", { p_user: u.user.id, p: pick(t) });
    if (error) throw new Error(error.message);
    return out(data);
  } catch (e) {
    return out({ error: (e as Error).message || "The purchase could not be checked." }, 400);
  }
});
