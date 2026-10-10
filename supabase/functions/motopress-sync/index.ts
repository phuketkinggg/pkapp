// Reads bookings from MotoPress Hotel Booking on the WordPress site and turns them into stays.
// Called every 15 minutes by a scheduled job (with a private token), or by staff with "Sync now".
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE = (Deno.env.get("MPHB_SITE") ?? "").trim().replace(/\/+$/, "");
const KEY = (Deno.env.get("MPHB_KEY") ?? "").trim();
const SECRET = (Deno.env.get("MPHB_SECRET") ?? "").trim();
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function allowed(req: Request): Promise<boolean> {
  const token = req.headers.get("x-sync-token");
  if (token) {
    const { data } = await admin.rpc("sync_token_ok", { p_token: token });
    return data === true;
  }
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return false;
  const { data: u } = await admin.auth.getUser(jwt);
  if (!u?.user) return false;
  const { data: s } = await admin.from("staff").select("role,active").eq("user_id", u.user.id).maybeSingle();
  return !!s && s.active && ["manager", "front_desk", "resort"].includes(s.role);
}

let useQuery = false;
async function mp(path: string): Promise<any> {
  const url = new URL(`${SITE}/wp-json/mphb/v1/${path}`);
  const headers: Record<string, string> = { Accept: "application/json" };
  if (useQuery) { url.searchParams.set("consumer_key", KEY); url.searchParams.set("consumer_secret", SECRET); }
  else headers.Authorization = "Basic " + btoa(`${KEY}:${SECRET}`);
  let r = await fetch(url, { headers });
  if ((r.status === 401 || r.status === 403) && !useQuery) { useQuery = true; return mp(path); }
  const text = await r.text();
  if (!r.ok) throw new Error(`MotoPress said ${r.status} for ${path.split("?")[0]}: ${text.slice(0, 200)}`);
  try { return JSON.parse(text); } catch { throw new Error(`MotoPress did not send data for ${path.split("?")[0]}`); }
}

// field names and types only, never the values, so no guest details leave the function in inspect mode
function shape(v: unknown, depth = 0): unknown {
  if (Array.isArray(v)) return v.length ? [shape(v[0], depth + 1)] : [];
  if (v && typeof v === "object") {
    if (depth > 3) return "object";
    const o: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) o[k] = shape(x, depth + 1);
    return o;
  }
  return typeof v;
}

const roomName = (t: unknown) => String((t && typeof t === "object" ? (t as any).rendered : t) ?? "").replace(/^Private:\s*/i, "").trim();
const bkkToday = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
const addDays = (d: string, n: number) => new Date(Date.parse(d + "T00:00:00Z") + n * 86400e3).toISOString().slice(0, 10);
function sourceName(b: any): string {
  if (!b.imported) return "Website";
  const p = String(b.ical_prodid ?? "").toLowerCase();
  if (p.includes("airbnb")) return "Airbnb";
  if (p.includes("booking.com")) return "Booking.com";
  if (p.includes("agoda")) return "Agoda";
  if (p.includes("expedia")) return "Expedia";
  return "Other calendar";
}
function must<T>(r: { data: T; error: any }): T { if (r.error) throw new Error(r.error.message); return r.data; }

async function sync() {
  const today = bkkToday(), from = addDays(today, -14);
  const out = { created: 0, updated: 0, cancelled: 0, removed: 0, skipped_old: 0, rooms_added: 0, relinked: 0, errors: [] as string[] };
  const seen = new Set<string>(); let complete = false;

  // rooms: one per MotoPress accommodation, matched by its id
  const accs: any[] = await mp("accommodations?per_page=100");
  const rooms = must(await admin.from("rooms").select("id,name,external_id,sort")) as any[];
  const roomByExt = new Map<string, string>();
  for (const r of rooms) if (r.external_id) roomByExt.set(r.external_id, r.id);
  const sorted = [...accs].sort((a, b) => roomName(a.title).localeCompare(roomName(b.title), "en", { numeric: true }));
  let sort = 100;
  for (const a of sorted) {
    sort++;
    const ext = String(a.id), name = roomName(a.title) || `Room ${a.id}`;
    if (roomByExt.has(ext)) continue;
    const same = rooms.find((r) => !r.external_id && r.name.toLowerCase() === name.toLowerCase());
    if (same) { must(await admin.from("rooms").update({ external_id: ext }).eq("id", same.id).select("id")); roomByExt.set(ext, same.id); continue; }
    const taken = rooms.some((r) => r.name.toLowerCase() === name.toLowerCase());
    const ins = must(await admin.from("rooms").insert({ name: taken ? `${name} (${ext})` : name, external_id: ext, sort, active: true }).select("id").single());
    roomByExt.set(ext, (ins as any).id); out.rooms_added++;
  }
  // the starter rooms "Bungalow 1" to "Bungalow 11" are switched off once real ones exist, if nothing uses them
  if (out.rooms_added) {
    const starters = rooms.filter((r) => !r.external_id && /^Bungalow \d+$/.test(r.name));
    for (const r of starters) {
      const { count } = await admin.from("stays").select("id", { count: "exact", head: true }).eq("room_id", r.id);
      if (!count) await admin.from("rooms").update({ active: false }).eq("id", r.id);
    }
  }

  // booking sources used for stays
  const srcRows = must(await admin.from("booking_sources").select("id,name")) as any[];
  const srcId = async (name: string) => {
    const hit = srcRows.find((s) => s.name.toLowerCase() === name.toLowerCase());
    if (hit) return hit.id;
    const ins = must(await admin.from("booking_sources").insert({ name }).select("id,name").single()) as any;
    srcRows.push(ins); return ins.id;
  };

  // our own emails (the desk often types the business email on bookings): never use them to match a guest
  const staffEmails = new Set((must(await admin.from("staff").select("email")) as any[]).map((r) => String(r.email ?? "").trim().toLowerCase()).filter(Boolean));
  const ownEmail = (e: string | null) => !!e && (staffEmails.has(e) || /@(phuketking\.com|pangeaglobalwellness\.com)$/.test(e) || /\.pangeaglobalwellness\.com$/.test(e));
  const guestName = (c: any, ra: any, b: any) => [c.first_name, c.last_name].map((x: unknown) => String(x ?? "").trim()).filter(Boolean).join(" ")
    || String(ra.guest_name ?? "").trim() || `${sourceName(b)} guest`;
  const newGuest = async (name: string, email: string | null, c: any, b: any) =>
    (must(await admin.from("customers").insert({ name: name.slice(0, 80), email, phone: String(c.phone ?? "").trim() || null, tier: "train", price_group: "standard", notes: `From a ${sourceName(b)} booking` }).select("id").single()) as any).id as string;
  const custCache = new Map<string, any>();
  const custOf = async (id: string) => {
    if (!custCache.has(id)) custCache.set(id, must(await admin.from("customers").select("id,name,email").eq("id", id).maybeSingle()));
    return custCache.get(id);
  };

  // bookings, newest first, until we are well past anything still relevant
  for (let page = 1; page <= 40; page++) {
    const list: any[] = await mp(`bookings?per_page=100&page=${page}&orderby=date&order=desc`);
    for (const b of list) {
      if (!b.check_out_date || b.check_out_date < from) { out.skipped_old++; continue; }
      // Airbnb sends dates the owner blocked as "Airbnb (Not available)": those are not guests
      if (b.imported && sourceName(b) === "Airbnb" && /not available/i.test(String(b.ical_summary ?? ""))) continue;
      const cancelled = ["cancelled", "abandoned"].includes(String(b.status));
      const src = await srcId(sourceName(b));
      const c = b.customer ?? {};
      const rawEmail = String(c.email ?? "").trim().toLowerCase() || null;
      const email = ownEmail(rawEmail) ? null : rawEmail;
      const ras: any[] = Array.isArray(b.reserved_accommodations) && b.reserved_accommodations.length ? b.reserved_accommodations : [{}];
      for (let i = 0; i < ras.length; i++) {
        const ra = ras[i], ext = `mphb:${b.id}:${i}`;
        seen.add(ext);
        try {
          const room = roomByExt.get(String(ra.accommodation ?? ""));
          if (!room) { out.errors.push(`Booking ${b.id}: room ${ra.accommodation ?? "?"} not found`); continue; }
          const guests = [ra.adults ? `${ra.adults} adult${ra.adults > 1 ? "s" : ""}` : "", ra.children ? `${ra.children} child${ra.children > 1 ? "ren" : ""}` : ""].filter(Boolean).join(", ") || null;
          const existing = must(await admin.from("stays").select("id,status,customer_id").eq("external_id", ext).maybeSingle()) as any;
          const base: Record<string, unknown> = { room_id: room, check_in: b.check_in_date, check_out: b.check_out_date, source_id: src, guests };
          if (existing) {
            const patch: Record<string, unknown> = { ...base };
            if (cancelled && existing.status === "booked") { patch.status = "cancelled"; out.cancelled++; }
            if (!cancelled && existing.status === "cancelled") patch.status = "booked";
            if (existing.status === "in" || existing.status === "out") { delete patch.check_in; delete patch.room_id; }
            // stays matched to a guest only through our own email get their own guest, by the name on the booking
            if (existing.customer_id) {
              const cur = await custOf(existing.customer_id);
              const nm = guestName(c, ra, b);
              if (cur && ownEmail(String(cur.email ?? "").toLowerCase()) && cur.name.toLowerCase() !== nm.toLowerCase()) {
                patch.customer_id = await newGuest(nm, email, c, b); out.relinked++;
              }
            }
            must(await admin.from("stays").update(patch).eq("id", existing.id).select("id"));
            out.updated++; continue;
          }
          if (cancelled) continue;
          // a calendar re-import can give the same booking a new number: adopt the stay instead of doubling it
          const clash = must(await admin.from("stays").select("id,external_id,check_in,check_out").eq("room_id", room).neq("status", "cancelled")
            .lt("check_in", b.check_out_date).gt("check_out", b.check_in_date).limit(1)) as any[];
          if (clash.length) {
            const k = clash[0];
            if (String(k.external_id ?? "").startsWith("mphb:") && k.check_in === b.check_in_date && k.check_out === b.check_out_date && !seen.has(k.external_id)) {
              must(await admin.from("stays").update({ external_id: ext, source_id: src, guests }).eq("id", k.id).select("id"));
              out.updated++; continue;
            }
            if (out.errors.length < 20) out.errors.push(`Booking ${b.id}: clashes with a stay already in the app for that room and dates`);
            continue;
          }
          // the guest: same email means same customer, otherwise a new one
          let cid: string | null = null;
          if (email) {
            const hit = must(await admin.from("customers").select("id").eq("is_agency", false).ilike("email", email).order("created_at").limit(1)) as any[];
            if (hit.length) cid = hit[0].id;
          }
          if (!cid) cid = await newGuest(guestName(c, ra, b), email, c, b);
          const past = b.check_out_date < today;
          must(await admin.from("stays").insert({ ...base, customer_id: cid, external_id: ext, status: past ? "out" : "booked", settled: past,
            notes: b.imported && b.ical_summary ? String(b.ical_summary).slice(0, 200) : (b.note ? String(b.note).slice(0, 300) : null) }).select("id"));
          out.created++;
        } catch (e) {
          if (out.errors.length < 20) out.errors.push(`Booking ${b.id}: ${(e as Error).message}`);
        }
      }
    }
    if (list.length < 100) { complete = true; break; }
    if (list.every((b) => (b.check_out_date ?? "") < from && String(b.date_created ?? "").slice(0, 10) < addDays(today, -400))) { complete = true; break; }
  }
  // bookings that were deleted in MotoPress (for example a calendar booking that went away) are cancelled here too
  if (complete) {
    const mine = must(await admin.from("stays").select("id,external_id").like("external_id", "mphb:%").eq("status", "booked").gte("check_out", today)) as any[];
    for (const st of mine) if (!seen.has(st.external_id)) {
      must(await admin.from("stays").update({ status: "cancelled", notes: "No longer in MotoPress" }).eq("id", st.id).select("id"));
      out.removed++;
    }
  }
  const summary = { at: new Date().toISOString(), ...out };
  await admin.from("app_settings").update({ value: JSON.stringify(summary), updated_at: new Date().toISOString() }).eq("key", "motopress_last_sync");
  return summary;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!(await allowed(req))) return json({ error: "Not allowed." }, 401);
  if (!SITE || !KEY || !SECRET) return json({ error: "The MotoPress secrets are missing in Supabase." }, 400);
  const body = await req.json().catch(() => ({}));
  try {
    if (body.mode === "inspect") {
      const bookings = await mp("bookings?per_page=5&orderby=date&order=desc");
      const accs = await mp("accommodations?per_page=100");
      const statuses: Record<string, number> = {};
      const many = await mp("bookings?per_page=100&orderby=date&order=desc");
      for (const b of many) statuses[b.status] = (statuses[b.status] ?? 0) + 1;
      return json({
        auth: useQuery ? "query" : "basic",
        booking_fields: bookings.length ? shape(bookings[0]) : null,
        statuses,
        imported_values: [...new Set(many.map((b: any) => JSON.stringify([b.imported, b.ical_prodid ?? null, b.ical_summary ? "has summary" : null])))].slice(0, 10),
        accommodations: accs.map((a: any) => ({ id: a.id, title: typeof a.title === "object" ? a.title?.rendered : a.title, type: a.accommodation_type_id ?? a.accommodation_type ?? null })),
      });
    }
    return json(await sync());
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 502);
  }
});
