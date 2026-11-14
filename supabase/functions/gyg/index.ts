// GetYourGuide connection (feature gyg_connect): GetYourGuide calls this address to see what is free and to book.
// Paths (GetYourGuide supplier API v1): GET 1/get-availabilities/, POST 1/reserve/, 1/cancel-reservation/, 1/book/,
// 1/cancel-booking/, 1/notify/, GET 1/suppliers/{id}/products/, 1/products/{id}, 1/products/{id}/pricing-categories/.
// It signs in with Basic auth; the user name and password are made by the database and shown to the manager.
// Every request goes to public.gyg_api, which checks the sign in and does the work. Always HTTP 200, as GetYourGuide expects.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const out = (b: unknown) => new Response(JSON.stringify(b), { status: 200, headers: { "Content-Type": "application/json" } });
const fail = (c: string, m: string) => out({ errorCode: c, errorMessage: m });

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/gyg\/?/, "").replace(/\/+$/, "");
  let user = "", pass = "";
  const a = req.headers.get("authorization") ?? "";
  if (/^basic /i.test(a)) {
    try { const t = atob(a.slice(6).trim()); const i = t.indexOf(":"); user = t.slice(0, i); pass = t.slice(i + 1); } catch (_e) { /* wrong format */ }
  }
  if (!user) return fail("AUTHORIZATION_FAILURE", "Sign in with Basic auth.");
  const query: Record<string, string> = {};
  url.searchParams.forEach((v, k) => { query[k] = v; });
  let data: Record<string, unknown> = {};
  if (req.method === "POST") {
    const b = await req.json().catch(() => null);
    if (!b || typeof b !== "object") return fail("VALIDATION_FAILURE", "The body must be JSON.");
    data = ((b as { data?: Record<string, unknown> }).data ?? {}) as Record<string, unknown>;
  }
  let op = "", m: RegExpMatchArray | null;
  if (path === "1/get-availabilities") op = "avail";
  else if (path === "1/reserve") op = "reserve";
  else if (path === "1/cancel-reservation") op = "cancel_res";
  else if (path === "1/book") op = "book";
  else if (path === "1/cancel-booking") op = "cancel_book";
  else if (path === "1/notify") op = "notify";
  else if ((m = path.match(/^1\/suppliers\/([^/]+)\/products$/))) { op = "products"; query.supplierId = decodeURIComponent(m[1]); }
  else if ((m = path.match(/^1\/products\/([^/]+)\/pricing-categories$/))) { op = "categories"; query.productId = decodeURIComponent(m[1]); }
  else if ((m = path.match(/^1\/products\/([^/]+)$/))) { op = "product"; query.productId = decodeURIComponent(m[1]); }
  else return fail("VALIDATION_FAILURE", "Unknown request: " + path);
  const { data: r, error } = await admin.rpc("gyg_api", { p: { op, user, pass, query, data } });
  if (error) return fail("INTERNAL_SYSTEM_FAILURE", error.message.slice(0, 200));
  return out(r);
});
