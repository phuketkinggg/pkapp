// Public website data for phuketking.com pages: packages with standard prices, the weekly timetable, the private price, and photos and text the manager has changed.
// Read only. Nothing about customers, staff pay or money taken.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (b: unknown) => new Response(JSON.stringify(b), { headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "public, max-age=60" } });
const today = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const [pk, cl, src, ph, tx, ga] = await Promise.all([
      admin.from("packages").select("id,name,price_thb,covers,visit_limit,per_week_limit,duration_days,audience,addon_fz_thb,notes").eq("active", true).not("price_thb", "is", null).order("price_thb"),
      admin.from("classes").select("day,start_time,title,discipline,off_from,off_to"),
      admin.from("booking_sources").select("price_thb").ilike("name", "direct").maybeSingle(),
      admin.from("app_settings").select("value").eq("key", "site_photos").maybeSingle(),
      admin.from("app_settings").select("value").eq("key", "site_texts").maybeSingle(),
      admin.from("app_settings").select("value").eq("key", "site_gallery").maybeSingle(),
    ]);
    let photos: Record<string, string> = {};
    try { photos = JSON.parse(ph.data?.value ?? "{}") ?? {}; } catch { photos = {}; }
    let texts: Record<string, string> = {};
    try { texts = JSON.parse(tx.data?.value ?? "{}") ?? {}; } catch { texts = {}; }
    let gallery: Record<string, unknown> = {};
    try { gallery = JSON.parse(ga.data?.value ?? "{}") ?? {}; } catch { gallery = {}; }
    const t = today();
    return json({
      today: t,
      private_price: src.data?.price_thb ?? null,
      photos,
      texts,
      gallery,
      packages: (pk.data ?? []).filter((p) => (p.audience || "all") === "all").map((p) => ({
        name: p.name, price: p.price_thb, covers: p.covers ?? [], visits: p.visit_limit, per_week: p.per_week_limit, days: p.duration_days, fz: p.addon_fz_thb, notes: p.notes ?? "" })),
      classes: (cl.data ?? []).map((k) => ({ day: k.day, time: String(k.start_time ?? "").slice(0, 5), title: k.title, discipline: k.discipline,
        off: !!(k.off_from && t >= k.off_from && t <= (k.off_to ?? k.off_from)) })).sort((a, b) => a.day - b.day || a.time.localeCompare(b.time)),
    });
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
