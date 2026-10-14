// Room calendars, the way Booking.com, Airbnb and Agoda talk to each other.
// GET  ?r=<room id>&t=<room token>   our calendar for that room, for them to read (no guest names in it)
// POST {mode:"import"}               read their calendars into our Stays (the 15 minute job, or a manager's "Sync now")
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const bkkToday = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
const ymd = (d: string) => `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}`;
const icsDate = (d: string) => d.replaceAll("-", "");
const addDays = (d: string, n: number) => new Date(Date.parse(d + "T00:00:00Z") + n * 864e5).toISOString().slice(0, 10);
const esc = (s: string) => s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\n/g, "\\n");

type Feed = { name?: string; url?: string };
type Ev = { uid: string; start: string; end: string; summary: string; desc: string };

// ---------- export ----------
async function exportRoom(roomId: string, token: string) {
  const { data: room } = await admin.from("rooms").select("id,name,ical_token,active").eq("id", roomId).maybeSingle();
  if (!room || !token || room.ical_token !== token) return new Response("Not found", { status: 404 });
  const from = addDays(bkkToday(), -30);
  const { data: stays } = await admin.from("stays").select("id,check_in,check_out,status,ical_feed").eq("room_id", roomId)
    .neq("status", "cancelled").gte("check_out", from).order("check_in");
  const now = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Phuket King//Rooms//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", `X-WR-CALNAME:${esc("Pangea " + room.name)}`];
  for (const s of stays ?? []) {
    if (!s.check_in || !s.check_out || s.check_out <= s.check_in) continue;
    lines.push("BEGIN:VEVENT", `UID:${s.id}@phuketking`, `DTSTAMP:${now}`, `DTSTART;VALUE=DATE:${icsDate(s.check_in)}`, `DTEND;VALUE=DATE:${icsDate(s.check_out)}`,
      "SUMMARY:Not available", "TRANSP:OPAQUE", "END:VEVENT");
  }
  lines.push("END:VCALENDAR");
  return new Response(lines.join("\r\n") + "\r\n", { headers: { "Content-Type": "text/calendar; charset=utf-8", "Cache-Control": "no-store" } });
}

// ---------- import ----------
function parse(text: string): Ev[] {
  const raw = text.replace(/\r\n[ \t]/g, "").replace(/\n[ \t]/g, "").split(/\r?\n/);
  const out: Ev[] = []; let cur: Record<string, string> | null = null;
  for (const line of raw) {
    if (line === "BEGIN:VEVENT") { cur = {}; continue; }
    if (line === "END:VEVENT") {
      if (cur && cur.DTSTART) {
        const s = cur.DTSTART.match(/(\d{8})/)?.[1], e = (cur.DTEND || "").match(/(\d{8})/)?.[1];
        if (s) out.push({ uid: cur.UID || `${s}-${e}`, start: ymd(s), end: e ? ymd(e) : addDays(ymd(s), 1), summary: (cur.SUMMARY || "").trim(), desc: (cur.DESCRIPTION || "").replace(/\\n/g, " ").replace(/\\,/g, ",").trim() });
      }
      cur = null; continue;
    }
    if (!cur) continue;
    const i = line.indexOf(":"); if (i < 0) continue;
    const key = line.slice(0, i).split(";")[0].toUpperCase();
    if (!(key in cur)) cur[key] = line.slice(i + 1);
  }
  return out;
}

async function sourceId(name: string) {
  const { data } = await admin.from("booking_sources").select("id,name");
  const hit = (data ?? []).find((s) => String(s.name).toLowerCase() === name.toLowerCase());
  if (hit) return hit.id;
  const { data: made } = await admin.from("booking_sources").insert({ name }).select("id").single();
  return made?.id ?? null;
}

async function importAll() {
  const today = bkkToday();
  const { data: rooms } = await admin.from("rooms").select("id,name,ical_feeds").eq("active", true);
  const res = { at: new Date().toISOString(), created: 0, updated: 0, cancelled: 0, feeds: 0, errors: [] as string[] };
  for (const room of rooms ?? []) {
    const feeds: Feed[] = Array.isArray(room.ical_feeds) ? room.ical_feeds : [];
    for (const f of feeds) {
      const name = String(f.name || "Booking site").slice(0, 40), url = String(f.url || "");
      if (!/^https:\/\//i.test(url)) continue;
      res.feeds++;
      let text = "";
      try {
        const r = await fetch(url, { headers: { "User-Agent": "PhuketKing-Calendar/1.0" }, signal: AbortSignal.timeout(20000) });
        if (!r.ok) throw new Error(`answered ${r.status}`);
        text = await r.text();
        if (!/BEGIN:VCALENDAR/.test(text)) throw new Error("did not send a calendar");
      } catch (e) { res.errors.push(`${room.name}, ${name}: could not read the calendar (${(e as Error).message}).`); continue; }
      // Airbnb marks host blocks as "Not available"; only "Reserved" is a guest. Booking.com and others send every booking as closed dates.
      const evs = parse(text).filter((e) => e.end > today && e.end > e.start && !/^airbnb\s*\(not available\)/i.test(e.summary));
      const feedKey = `${room.id}:${name.toLowerCase()}`;
      const src = await sourceId(name);
      const seen = new Set<string>();
      for (const ev of evs) {
        const ext = `ical:${feedKey}:${ev.uid}`.slice(0, 300);
        seen.add(ext);
        const { data: mine } = await admin.from("stays").select("id,check_in,check_out,status,dates_locked").eq("external_id", ext).maybeSingle();
        if (mine) {
          if (mine.status === "cancelled") continue;
          if (!mine.dates_locked && (mine.check_in !== ev.start || mine.check_out !== ev.end)) {
            const { error } = await admin.from("stays").update({ check_in: ev.start, check_out: ev.end, ical_seen_at: new Date().toISOString() }).eq("id", mine.id);
            if (error) res.errors.push(`${room.name}: ${name} moved a booking to ${ev.start}, but ${error.message}`); else res.updated++;
          } else await admin.from("stays").update({ ical_seen_at: new Date().toISOString() }).eq("id", mine.id);
          continue;
        }
        // a block that matches one of our own bookings is just our calendar coming back: skip it
        const { data: over } = await admin.from("stays").select("id,ical_feed,external_id").eq("room_id", room.id).neq("status", "cancelled")
          .lt("check_in", ev.end).gt("check_out", ev.start);
        const others = (over ?? []).filter((s) => s.ical_feed !== feedKey);
        if (others.length) {
          const fromSameSite = others.some((s) => s.ical_feed && s.ical_feed !== feedKey);
          if (fromSameSite) res.errors.push(`${room.name}: ${name} has a booking ${ev.start} to ${ev.end} that clashes with another site's booking. Check for a double booking.`);
          continue;
        }
        const label = `${name} guest, ${new Date(ev.start + "T00:00:00Z").toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" })}`;
        const { data: cust, error: ce } = await admin.from("customers").insert({ name: label, tags: ["ota"], lead_source: name, notes: `From the ${name} calendar. Rename or merge when the guest arrives.` }).select("id").single();
        if (ce || !cust) { res.errors.push(`${room.name}: could not add the ${name} guest (${ce?.message}).`); continue; }
        const { error } = await admin.from("stays").insert({ customer_id: cust.id, room_id: room.id, check_in: ev.start, check_out: ev.end, status: "booked", source_id: src,
          external_id: ext, ical_feed: feedKey, ical_seen_at: new Date().toISOString(), settled: false, training_included: false,
          notes: (`${name} booking from its calendar. ${ev.summary}${ev.desc ? ". " + ev.desc : ""}`).slice(0, 300) });
        if (error) res.errors.push(`${room.name}: ${name} booking ${ev.start} to ${ev.end} could not be added: ${error.message}`); else res.created++;
      }
      // bookings gone from their calendar were cancelled there. Only after they are missing for an hour (several checks),
      // and never when the whole calendar comes back empty, which is more likely a glitch on their side.
      const { data: ours } = await admin.from("stays").select("id,external_id,check_in,ical_seen_at").eq("ical_feed", feedKey).in("status", ["booked"]).gte("check_in", today);
      if (!evs.length && (ours ?? []).length) { res.errors.push(`${room.name}, ${name}: the calendar came back empty, so no bookings were cancelled. Check ${name}.`); continue; }
      const cutoff = Date.now() - 3600e3;
      for (const s of ours ?? []) {
        if (s.external_id && !seen.has(s.external_id) && (!s.ical_seen_at || Date.parse(s.ical_seen_at) < cutoff)) {
          await admin.from("stays").update({ status: "cancelled", notes: `Cancelled on ${name} (gone from its calendar ${today}).` }).eq("id", s.id);
          res.cancelled++;
        }
      }
    }
  }
  await admin.from("app_settings").upsert({ key: "ical_last_sync", value: JSON.stringify(res), updated_at: new Date().toISOString() });
  return res;
}

async function isManagerOrDesk(req: Request) {
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return false;
  const { data: u } = await admin.auth.getUser(jwt);
  if (!u?.user) return false;
  const { data: s } = await admin.from("staff").select("role,active").eq("user_id", u.user.id).maybeSingle();
  return !!s && s.active && ["manager", "front_desk", "resort"].includes(s.role);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  if (req.method === "GET") return exportRoom(url.searchParams.get("r") ?? "", url.searchParams.get("t") ?? "");
  try {
    const body = await req.json().catch(() => ({}));
    if (body.mode !== "import") return json({ error: "Unknown mode." }, 400);
    const token = req.headers.get("x-sync-token");
    let ok = false;
    if (token) { const { data } = await admin.rpc("sync_token_ok", { p_token: token }); ok = data === true; }
    else ok = await isManagerOrDesk(req);
    if (!ok) return json({ error: "Not allowed." }, 401);
    return json(await importAll());
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
