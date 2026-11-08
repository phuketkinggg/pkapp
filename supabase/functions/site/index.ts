// Public website data for phuketking.com pages: packages with standard prices (and resident prices for the Thai page when switched on), the weekly timetable, the private price, and photos and text the manager has changed.
// Read only. Nothing about customers, staff pay or money taken. Staff: only the website team (name, title, text, photo, video).
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
    const [pk, cl, src, ph, tx, ga, st, fe] = await Promise.all([
      admin.from("packages").select("id,name,price_thb,price_local_thb,addon_fz_local_thb,covers,visit_limit,per_week_limit,duration_days,audience,addon_fz_thb,notes,clock,start_within_days,badge,was_thb").eq("active", true).not("price_thb", "is", null).order("price_thb"),
      admin.from("classes").select("day,start_time,end_time,title,discipline,off_from,off_to"),
      admin.from("booking_sources").select("price_thb").ilike("name", "direct").maybeSingle(),
      admin.from("app_settings").select("value").eq("key", "site_photos").maybeSingle(),
      admin.from("app_settings").select("value").eq("key", "site_texts").maybeSingle(),
      admin.from("app_settings").select("value").eq("key", "site_gallery").maybeSingle(),
      admin.from("staff").select("name,web_name,web_title,web_about,bio,photo_url,video_url,web_sort").eq("active", true).eq("web_show", true).order("web_sort").order("name"),
      admin.from("app_settings").select("value").eq("key", "features").maybeSingle(),
    ]);
    // feature switches (Settings, Features): the website team and its videos can be switched off
    let feat: Record<string, unknown> = {};
    try { feat = JSON.parse(fe.data?.value ?? "{}") ?? {}; } catch { feat = {}; }
    const on = (k: string) => feat[k] !== false;
    // the team on the website: set in the app, Staff (show on the website, title, text, photo and 360 video)
    const pub = (u: unknown) => typeof u === "string" && /^https:\/\/jijnshwduhgegacfvpkh\.supabase\.co\/storage\/v1\/object\/public\/(promos|coach-media)\//.test(u) ? u : null;
    const team = !on("web_team") ? [] : (st.data ?? []).map((x) => ({ name: x.web_name || x.name, title: x.web_title ?? "", about: x.web_about || x.bio || "", photo: pub(x.photo_url), video: on("profile_video") ? pub(x.video_url) : null }));
    let photos: Record<string, string> = {};
    try { photos = JSON.parse(ph.data?.value ?? "{}") ?? {}; } catch { photos = {}; }
    let texts: Record<string, string> = {};
    try { texts = JSON.parse(tx.data?.value ?? "{}") ?? {}; } catch { texts = {}; }
    let gallery: Record<string, unknown> = {};
    try { gallery = JSON.parse(ga.data?.value ?? "{}") ?? {}; } catch { gallery = {}; }
    const t = today();
    // the date this week's class on weekday wd (0 Monday) falls on, today or later: a class paused for that date shows as off all week
    const classDay = (td: string, wd: number) => { const d = new Date(td + "T12:00:00Z"); const now = (d.getUTCDay() + 6) % 7; d.setUTCDate(d.getUTCDate() + ((wd - now + 7) % 7)); return d.toISOString().slice(0, 10); };
    return json({
      today: t,
      private_price: src.data?.price_thb ?? null,
      photos,
      texts,
      gallery,
      team,
      packages: (pk.data ?? []).filter((p) => (p.audience || "all") === "all").map((p) => ({
        id: p.id, name: p.name, price: p.price_thb, covers: p.covers ?? [], visits: p.visit_limit, per_week: p.per_week_limit, days: p.duration_days, fz: p.addon_fz_thb, notes: p.notes ?? "",
        pick_start: p.clock === "purchase", start_within: p.start_within_days ?? null, badge: p.badge || null, was: p.was_thb && p.was_thb > p.price_thb ? p.was_thb : null })),
      // the Thai page price list: every package for residents, at the Local resident price where one is set, else the standard price (only when Resident prices on the website is on)
      residents: feat.web_residents !== true ? [] : (pk.data ?? []).filter((p) => ["all", "local"].includes(p.audience || "all"))
        .map((p) => ({ id: p.id, name: p.name, price: p.price_local_thb ?? p.price_thb, covers: p.covers ?? [], visits: p.visit_limit, per_week: p.per_week_limit, days: p.duration_days, fz: p.addon_fz_local_thb ?? p.addon_fz_thb ?? null })),
      classes: (cl.data ?? []).map((k) => ({ day: k.day, time: String(k.start_time ?? "").slice(0, 5), end: k.end_time ? String(k.end_time).slice(0, 5) : null, title: k.title, discipline: k.discipline,
        off: !!(k.off_from && ((d) => d >= k.off_from && d <= (k.off_to ?? k.off_from))(classDay(t, k.day))) })).sort((a, b) => a.day - b.day || a.time.localeCompare(b.time)),
    });
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
