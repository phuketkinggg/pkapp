// Google reviews for the website. Uses the Google Places API with the key in the Supabase secret GOOGLE_PLACES_KEY.
// Finds the gym on Google once (place id kept), then fetches rating, review count and up to 5 reviews.
// The answer is kept for 12 hours so Google is asked about twice a day (well inside the free allowance).
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = (Deno.env.get("GOOGLE_PLACES_KEY") ?? "").trim();
const QUERY = "Phuket King Muay Thai, Kathu, Phuket";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "public, max-age=1800" } });
let mem: { at: number; data: unknown } | null = null;

async function getSetting(k: string) { const { data } = await admin.from("app_settings").select("value,updated_at").eq("key", k).maybeSingle(); return data; }
async function setSetting(k: string, v: unknown) { await admin.from("app_settings").upsert({ key: k, value: JSON.stringify(v), updated_at: new Date().toISOString() }); }

async function placeId(): Promise<string> {
  const s = await getSetting("google_place");
  if (s?.value) { try { const v = JSON.parse(s.value); if (v.id) return v.id; } catch { /* look it up again */ } }
  const r = await fetch("https://places.googleapis.com/v1/places:searchText", {
    method: "POST", headers: { "Content-Type": "application/json", "X-Goog-Api-Key": KEY, "X-Goog-FieldMask": "places.id,places.displayName,places.formattedAddress" },
    body: JSON.stringify({ textQuery: QUERY, languageCode: "en" }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? "Google said " + r.status);
  const p = (j.places ?? [])[0];
  if (!p?.id) throw new Error("The gym was not found on Google.");
  await setSetting("google_place", { id: p.id, name: p.displayName?.text, address: p.formattedAddress });
  return p.id;
}
async function fresh() {
  const id = await placeId();
  const r = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(id)}?languageCode=en`, {
    headers: { "X-Goog-Api-Key": KEY, "X-Goog-FieldMask": "displayName,rating,userRatingCount,googleMapsUri,reviews" },
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? "Google said " + r.status);
  // deno-lint-ignore no-explicit-any
  const reviews = (j.reviews ?? []).filter((x: any) => (x.originalText?.text ?? x.text?.text ?? "").trim()).map((x: any) => ({
    author: x.authorAttribution?.displayName ?? "Google user",
    author_url: x.authorAttribution?.uri ?? null,
    rating: x.rating ?? null,
    when: x.relativePublishTimeDescription ?? "",
    text: (x.text?.text ?? x.originalText?.text ?? "").slice(0, 1200),
    url: x.googleMapsUri ?? null,
  }));
  return { configured: true, name: j.displayName?.text ?? "Phuket King Muay Thai", rating: j.rating ?? null, count: j.userRatingCount ?? 0,
    maps_url: j.googleMapsUri ?? null, write_url: "https://search.google.com/local/writereview?placeid=" + id, reviews, at: new Date().toISOString() };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!KEY) return json({ configured: false });
  if (mem && Date.now() - mem.at < 30 * 60e3) return json(mem.data);
  try {
    const s = await getSetting("google_reviews");
    if (s?.value) {
      const v = JSON.parse(s.value);
      if (v.at && Date.now() - Date.parse(v.at) < 12 * 3600e3) { mem = { at: Date.now(), data: v }; return json(v); }
    }
    const v = await fresh();
    await setSetting("google_reviews", v);
    mem = { at: Date.now(), data: v };
    return json(v);
  } catch (e) {
    const s = await getSetting("google_reviews").catch(() => null);
    if (s?.value) { try { return json(JSON.parse(s.value)); } catch { /* fall through */ } }
    return json({ configured: true, error: (e as Error).message, reviews: [] });
  }
});
