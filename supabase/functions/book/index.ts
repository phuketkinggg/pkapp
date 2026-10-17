// The public "Book your stay" page talks to this. No sign in.
// info:    rooms, price groups, seasons and the map (no guest details, ever)
// quote:   which rooms are free for some dates, and the price for each
// reserve: hold a room for 30 minutes and open a Stripe card payment for it
// status:  after paying, the page asks if the booking went through
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const PAGE = "https://phuketkinggg.github.io/pkapp/book.html";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const today = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
const addDays = (d: string, n: number) => new Date(Date.parse(d + "T00:00:00Z") + n * 864e5).toISOString().slice(0, 10);
const isDay = (d: unknown) => typeof d === "string" && /^\d{4}-\d{2}-\d{2}$/.test(d) && !isNaN(Date.parse(d));

type Season = { id: string; name: string; ranges?: { from: string; to: string }[] };
type Group = { id: string; name: string; rooms: string[]; prices: Record<string, number>; note?: string };
type Opt = { id: string; name: string; price: number; limit?: number };
type Extra = { id: string; name: string; kind: "pick" | "day" | "qty"; price?: number; covers?: string[]; per_day?: number; tiers?: { max: number; price: number }[]; addon?: { name: string; price: number }; options?: Opt[]; max?: number; unit?: string; note?: string };
type Rates = { base: string; seasons: Season[]; groups: Group[]; extras?: Extra[]; map?: { img?: string; pins?: Record<string, { x: number; y: number }> } };
type Item = { name: string; price: number; covers: string[]; limit?: number | null; days?: number | null; starts?: string | null; expires?: string | null };

async function rates(): Promise<Rates> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "room_rates").maybeSingle();
  try { const r = JSON.parse(data?.value ?? "{}"); return { base: r.base || "low", seasons: r.seasons || [], groups: r.groups || [], extras: r.extras || [], map: r.map || {} }; }
  catch { return { base: "low", seasons: [], groups: [] }; }
}
function inRange(md: string, r: { from: string; to: string }) { const a = r.from, b = r.to; if (!a || !b) return false; return a <= b ? md >= a && md <= b : md >= a || md <= b; }
function seasonOf(R: Rates, day: string) {
  const md = day.slice(5); let hit: Season | null = null;
  for (const s of R.seasons) if (s.id !== R.base && (s.ranges || []).some((r) => inRange(md, r))) hit = s;
  return hit || R.seasons.find((s) => s.id === R.base) || R.seasons[0] || null;
}
function quote(R: Rates, g: Group, from: string, to: string) {
  const nights: { day: string; season: string; price: number }[] = []; let total = 0, missing = false;
  for (let d = from; d < to; d = addDays(d, 1)) {
    const s = seasonOf(R, d), p = s ? Number(g.prices?.[s.id]) : NaN;
    if (!s || isNaN(p) || g.prices?.[s.id] == null) missing = true; else total += p;
    nights.push({ day: d, season: s?.name ?? "", price: p });
  }
  return { total, nights, missing };
}
async function roomsOn() {
  const { data } = await admin.from("rooms").select("id,name,sort,active").eq("active", true).order("sort");
  return data ?? [];
}
function checkDates(from: unknown, to: unknown) {
  if (!isDay(from) || !isDay(to)) return "Pick your dates.";
  const f = from as string, t = to as string;
  if (f < today()) return "The arrival date has passed.";
  if (t <= f) return "The leaving date must be after the arrival date.";
  if ((Date.parse(t) - Date.parse(f)) / 864e5 > 90) return "For more than 90 nights, message us.";
  if (f > addDays(today(), 540)) return "We take bookings up to 18 months ahead.";
  return null;
}
// what the guest picked on the page, priced here from the settings, never from the page
function extraItems(R: Rates, picks: unknown, from: string, to: string): Item[] {
  const nights = Math.round((Date.parse(to) - Date.parse(from)) / 864e5), out: Item[] = [];
  if (!Array.isArray(picks)) return out;
  for (const p of picks.slice(0, 20) as Record<string, unknown>[]) {
    const e = (R.extras || []).find((x) => x.id === p.id && !(x as { off?: boolean }).off); if (!e) continue;
    const covers = e.covers || [];
    if (e.kind === "pick") {
      const o = (e.options || []).find((x) => x.id === p.option); if (!o) continue;
      out.push({ name: `${e.name}, ${o.name}`, price: o.price, covers, limit: o.limit ?? null, starts: from, expires: addDays(to, 30) });
    } else if (e.kind === "day") {
      const days = Math.max(1, Math.min(nights, Math.round(Number(p.days) || nights)));
      const per = e.tiers?.length ? (e.tiers.find((t) => days <= t.max) ?? e.tiers[e.tiers.length - 1]).price : Number(e.price || 0);
      const add = p.addon && e.addon ? e.addon.price : 0;
      out.push({ name: `${e.name}${add ? ", " + e.addon!.name : ""}, ${days} day${days === 1 ? "" : "s"}`, price: (per + add) * days, covers,
        limit: e.per_day ? e.per_day * days : null, days, starts: from, expires: addDays(from, days - 1) });
    } else {
      const q = Math.max(1, Math.min(e.max || 10, Math.round(Number(p.qty) || 1)));
      out.push({ name: `${e.name}${e.unit ? " (" + e.unit + ")" : ""}${q > 1 ? " x " + q : ""}`, price: Number(e.price || 0) * q, covers, starts: from, expires: addDays(to, 30) });
    }
  }
  return out.filter((i) => i.price > 0);
}
async function takenRooms(from: string, to: string) {
  await admin.rpc("web_holds_cleanup");
  const { data } = await admin.from("stays").select("room_id").not("status", "in", "(cancelled,out)").lt("check_in", to).gt("check_out", from);
  return new Set((data ?? []).map((s) => s.room_id));
}
function backUrl(u: unknown): string {
  try {
    const x = new URL(String(u ?? ""));
    if (x.origin === "https://phuketkinggg.github.io" && x.pathname.startsWith("/pkapp")) return x.origin + x.pathname;
    if (["https://app.phuketking.com", "https://phuketking.com", "https://www.phuketking.com", "https://new.phuketking.com", "https://test.phuketking.com"].includes(x.origin)) return x.origin + x.pathname;
  } catch { /* fall through */ }
  return PAGE;
}
async function stripeSession(lines: { name: string; amount: number }[], amount: number, stayId: string, email: string, back: string) {
  const p = new URLSearchParams();
  p.set("mode", "payment");
  p.set("success_url", back + "?paid=1&ref=" + stayId);
  p.set("cancel_url", back + "?paid=0&ref=" + stayId);
  p.set("expires_at", String(Math.floor(Date.now() / 1000) + 30 * 60 + 30));
  lines.forEach((l, i) => {
    p.set(`line_items[${i}][quantity]`, "1");
    p.set(`line_items[${i}][price_data][currency]`, "thb");
    p.set(`line_items[${i}][price_data][unit_amount]`, String(Math.round(l.amount * 100)));
    p.set(`line_items[${i}][price_data][product_data][name]`, l.name.slice(0, 120));
  });
  p.set("payment_method_types[0]", "card");
  p.set("customer_email", email);
  for (const [k, v] of Object.entries({ kind: "stay", id: stayId, amount: String(amount) })) { p.set(`metadata[${k}]`, v); p.set(`payment_intent_data[metadata][${k}]`, v); }
  const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST", headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/x-www-form-urlencoded", "Stripe-Version": "2024-06-20" }, body: p,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `Stripe said ${r.status}`);
  return j.url as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const body = await req.json().catch(() => ({}));
  try {
    const R = await rates();
    if (body.mode === "info") {
      const rooms = await roomsOn();
      const inGroup = (id: string) => R.groups.find((g) => g.rooms.includes(id));
      return json({
        today: today(),
        seasons: R.seasons.map((s) => ({ id: s.id, name: s.name, ranges: s.ranges || [], base: s.id === R.base })),
        groups: R.groups.map((g) => ({ id: g.id, name: g.name, note: g.note || "", prices: g.prices })),
        rooms: rooms.map((r) => ({ id: r.id, name: r.name, group: inGroup(r.id)?.id ?? null })),
        extras: (R.extras || []).filter((e) => !(e as { off?: boolean }).off).map((e) => ({ id: e.id, name: e.name, kind: e.kind, price: e.price ?? null, tiers: e.tiers ?? null, addon: e.addon ?? null, options: e.options ?? null, max: e.max ?? null, unit: e.unit ?? null, note: e.note ?? "" })),
        map: R.map?.img ? { img: R.map.img, pins: R.map.pins || {} } : null,
      });
    }
    if (body.mode === "quote") {
      const bad = checkDates(body.from, body.to); if (bad) return json({ error: bad });
      const from = body.from as string, to = body.to as string;
      const taken = await takenRooms(from, to), rooms = await roomsOn();
      const out = rooms.map((r) => {
        const g = R.groups.find((x) => x.rooms.includes(r.id));
        if (!g) return { id: r.id, state: "off" };
        if (taken.has(r.id)) return { id: r.id, group: g.id, state: "taken" };
        const q = quote(R, g, from, to);
        return q.missing ? { id: r.id, group: g.id, state: "off" } : { id: r.id, group: g.id, state: "free", total: q.total, nights: q.nights };
      });
      return json({ from, to, nights: Math.round((Date.parse(to) - Date.parse(from)) / 864e5), rooms: out });
    }
    if (body.mode === "reserve") {
      if (!KEY) return json({ error: "Card payments are not set up yet. Message us to book." });
      const bad = checkDates(body.from, body.to); if (bad) return json({ error: bad });
      const from = body.from as string, to = body.to as string, roomId = String(body.room_id ?? "");
      const g = R.groups.find((x) => x.rooms.includes(roomId)); if (!g) return json({ error: "That room can not be booked online." });
      const q = quote(R, g, from, to); if (q.missing || !(q.total >= 20)) return json({ error: "That room has no price for those dates. Message us." });
      const { data: rm } = await admin.from("rooms").select("name").eq("id", roomId).maybeSingle();
      const items = extraItems(R, body.extras, from, to), total = q.total + items.reduce((t, i) => t + i.price, 0);
      await admin.rpc("web_holds_cleanup");
      const { data, error } = await admin.rpc("web_reserve", { p_room: roomId, p_from: from, p_to: to, p_price: q.total, p_name: String(body.name ?? ""), p_email: String(body.email ?? ""),
        p_phone: String(body.phone ?? ""), p_guests: String(body.guests ?? ""), p_note: String(body.note ?? "").slice(0, 400) });
      if (error) return json({ error: error.message });
      const stayId = (data as { stay_id: string }).stay_id;
      try {
        if (items.length) { const { error: ie } = await admin.rpc("web_add_items", { p_stay: stayId, p_items: items }); if (ie) throw new Error(ie.message); }
        const lines = [{ name: `Pangea Resort, ${rm?.name ?? "room"}, ${from} to ${to}`, amount: q.total }].concat(items.map((i) => ({ name: i.name, amount: i.price })));
        const url = await stripeSession(lines, total, stayId, (data as { email: string }).email, backUrl(body.back));
        return json({ url, stay_id: stayId, total });
      } catch (e) {
        await admin.from("stays").update({ status: "cancelled", hold_until: null, notes: "Website booking, card payment could not start." }).eq("id", stayId);
        await admin.from("purchases").update({ cancelled: true }).eq("for_stay", stayId).eq("ordered_in_app", true);
        return json({ error: "Card payment could not start. Try again, or message us. " + (e as Error).message });
      }
    }
    if (body.mode === "status") {
      if (!/^[0-9a-f-]{36}$/.test(String(body.ref ?? ""))) return json({ error: "Not found." });
      const { data } = await admin.rpc("web_booking_status", { p_stay: body.ref });
      return json(data ?? { error: "Not found." });
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
