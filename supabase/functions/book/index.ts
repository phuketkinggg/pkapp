// The public "Book your stay" page talks to this. No sign in.
// info:    rooms, price groups, seasons and the map (no guest details, ever)
// quote:   which rooms are free for some dates, and the price for each
// reserve: hold a room for 30 minutes and open a Stripe card payment for it (with the website offer: direct booking discount, gift for long stays)
// reserve with pay:"pp": Thai QR (PromptPay) straight to our bank: returns the QR instead of a Stripe page
// claim:   the guest tapped "I have paid": the room is held 12 hours and the desk checks the bank
// status:  after paying, the page asks if the booking went through
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// Thai baht goes to the Thai Stripe account (STRIPE_TH_SECRET_KEY) once it is set. US dollars, pounds and euros go to the main account.
const KEY_MAIN = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").trim();
const KEY_TH = (Deno.env.get("STRIPE_TH_SECRET_KEY") ?? "").trim();
const KEY = KEY_TH || KEY_MAIN;

// customers paying by card always pay the card fee (Settings, Card fee and tax, normally 3% + 10 THB, the 10 THB only under 2,000 THB), shown as its own line on the Stripe page
type CardRule = { pct: number; fixed: number; under: number };
// the fee is a percent plus a fixed amount; above "under" baht the fixed part is not charged (we cover it)
async function cardRule(): Promise<CardRule> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "pay_extras").maybeSingle();
  let j: Record<string, unknown> = {}; try { j = JSON.parse(data?.value ?? "{}"); } catch { /* defaults */ }
  const n = (v: unknown, d: number, max: number) => { const x = Number(v); return v != null && Number.isFinite(x) && x >= 0 && x <= max ? x : d; };
  return { pct: n(j.card_pct, 3, 20), fixed: n(j.card_fixed, 10, 1000), under: n(j.card_fixed_under, 2000, 10000000) };
}
const cardFee = (amount: number, r: CardRule) => amount > 0 ? Math.round(amount * r.pct / 100) + (r.fixed > 0 && amount < r.under ? r.fixed : 0) : 0;
const cardLabel = (amount: number, r: CardRule) => `Card fee (${r.pct}%${r.fixed > 0 && amount < r.under ? ` + ${r.fixed} THB` : ""})`;
const keyFor = (cur: string) => (cur === "thb" ? KEY_TH || KEY_MAIN : KEY_MAIN);
const CURS = ["thb", "usd", "gbp", "eur"];
// exchange rates: how much of each currency for 1 THB, refreshed every 12 hours, plus a small margin (app_settings fx.margin, in %)
async function fx(): Promise<Record<string, number>> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "fx").maybeSingle();
  let c: { at?: string; rates?: Record<string, number>; margin?: number } = {};
  try { c = JSON.parse(data?.value ?? "{}"); } catch { /* empty */ }
  let rates = c.rates;
  if (!(c.at && rates && Date.now() - Date.parse(c.at) < 12 * 3600e3)) {
    const tries: [string, (j: { rates?: Record<string, number> }) => Record<string, number> | null][] = [
      ["https://api.frankfurter.dev/v1/latest?base=THB&symbols=USD,GBP,EUR", (j) => j?.rates?.USD ? { usd: j.rates.USD, gbp: j.rates.GBP, eur: j.rates.EUR } : null],
      ["https://open.er-api.com/v6/latest/THB", (j) => j?.rates?.USD ? { usd: j.rates.USD, gbp: j.rates.GBP, eur: j.rates.EUR } : null],
    ];
    for (const [u, pick] of tries) {
      try { const r = await fetch(u); const got = pick(await r.json()); if (got) { rates = got; break; } } catch { /* next */ }
    }
    if (rates && rates !== c.rates) {
      const v = JSON.stringify({ ...c, at: new Date().toISOString(), rates });
      const { data: up } = await admin.from("app_settings").update({ value: v }).eq("key", "fx").select("key");
      if (!up?.length) await admin.from("app_settings").insert({ key: "fx", value: v });
    }
  }
  if (!rates) return { thb: 1 };
  const m = 1 + (Number.isFinite(Number(c.margin)) ? Number(c.margin) : 3) / 100;
  return { thb: 1, usd: rates.usd * m, gbp: rates.gbp * m, eur: rates.eur * m };
}
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
type Extra = { id: string; name: string; kind: "pick" | "day" | "qty"; price?: number; covers?: string[]; per_day?: number; tiers?: { max: number; price: number }[]; addon?: { name: string; price: number }; options?: Opt[]; any?: boolean; any_max?: number; max?: number; unit?: string; note?: string };
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
// the website offer (app_settings stay_offer): a direct booking discount on the room, and a gift for long stays
type Offer = { on: boolean; pct: number; gift_nights: number; gift: string; includes: string };
async function offer(): Promise<Offer> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "stay_offer").maybeSingle();
  let j: Record<string, unknown> = {}; try { j = JSON.parse(data?.value ?? "{}"); } catch { /* none */ }
  const on = j.on === true, pct = Math.max(0, Math.min(50, Number(j.pct) || 0)), gn = Math.max(0, Math.min(90, Math.round(Number(j.gift_nights) || 0)));
  // includes: what every room comes with (for example unlimited group classes for 1 person), shown on each room; not part of the offer switch
  return { on, pct: on ? pct : 0, gift_nights: on && String(j.gift ?? "").trim() ? gn : 0, gift: on ? String(j.gift ?? "").trim().slice(0, 80) : "", includes: String(j.includes ?? "").trim().slice(0, 120) };
}
const offPrice = (full: number, o: Offer) => o.pct > 0 ? Math.round(full * (100 - o.pct) / 100) : full;
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
// any number of sessions: the price runs smoothly between the packages, rounded to 50 THB (same sum as book.html)
function packPrice(opts: Opt[], n: number): number {
  const p = opts.filter((o) => (o.limit ?? 0) > 0).sort((a, b) => a.limit! - b.limit!); if (!p.length || !(n > 0)) return 0;
  let lo: Opt | null = null, hi: Opt | null = null; for (const o of p) { if (o.limit! <= n) lo = o; else if (!hi) hi = o; }
  if (lo && lo.limit === n) return lo.price;
  const v = !lo ? n * hi!.price / hi!.limit! : !hi ? n * lo.price / lo.limit! : lo.price + (n - lo.limit!) * (hi.price - lo.price) / (hi.limit! - lo.limit!);
  return Math.round(v / 50) * 50;
}
function anyName(e: Extra, n: number): string {
  const p = (e.options || []).filter((o) => (o.limit ?? 0) > 0), one = p.find((o) => o.limit === 1), many = p.find((o) => o.limit! > 1);
  const w1 = one ? one.name.replace(/^\d+\s*/, "") : "session", w2 = many ? many.name.replace(/^\d+\s*/, "") : w1 + "s"; return `${n} ${n === 1 ? w1 : w2}`;
}
// what the guest picked on the page, priced here from the settings, never from the page
function extraItems(R: Rates, picks: unknown, from: string, to: string): Item[] {
  const nights = Math.round((Date.parse(to) - Date.parse(from)) / 864e5), out: Item[] = [];
  if (!Array.isArray(picks)) return out;
  for (const p of picks.slice(0, 20) as Record<string, unknown>[]) {
    const e = (R.extras || []).find((x) => x.id === p.id && !(x as { off?: boolean }).off); if (!e) continue;
    const covers = e.covers || [];
    if (e.kind === "pick") {
      if (p.option === "any" && e.any) {
        const n = Math.max(1, Math.min(e.any_max || 30, Math.round(Number(p.n) || 1))), price = packPrice(e.options || [], n); if (!price) continue;
        out.push({ name: `${e.name}, ${anyName(e, n)}`, price, covers, limit: n, starts: from, expires: addDays(to, 30) }); continue;
      }
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
// qr: Thai QR (PromptPay) through the Thai Stripe account, THB only, no card fee. Stripe confirms the payment by itself, like a card.
async function stripeSession(lines: { name: string; amount: number }[], amount: number, stayId: string, email: string, back: string, cur = "thb", rate = 1, qr = false) {
  const p = new URLSearchParams();
  p.set("mode", "payment");
  p.set("success_url", back + "?paid=1&ref=" + stayId);
  p.set("cancel_url", back + "?paid=0&ref=" + stayId);
  p.set("expires_at", String(Math.floor(Date.now() / 1000) + 30 * 60 + 30));
  lines.forEach((l, i) => {
    p.set(`line_items[${i}][quantity]`, "1");
    p.set(`line_items[${i}][price_data][currency]`, cur);
    p.set(`line_items[${i}][price_data][unit_amount]`, String(Math.round(l.amount * rate * 100)));
    p.set(`line_items[${i}][price_data][product_data][name]`, l.name.slice(0, 120));
  });
  p.set("payment_method_types[0]", qr ? "promptpay" : "card");
  p.set("customer_email", email);
  const rule = await cardRule(), fee = qr ? 0 : cardFee(amount, rule);
  if (fee > 0) { const i = lines.length; p.set(`line_items[${i}][quantity]`, "1"); p.set(`line_items[${i}][price_data][currency]`, cur); p.set(`line_items[${i}][price_data][unit_amount]`, String(Math.round(fee * rate * 100))); p.set(`line_items[${i}][price_data][product_data][name]`, cardLabel(amount, rule)); }
  // amount is always the THB value; the app records the stay in THB whatever currency was charged
  for (const [k, v] of Object.entries({ kind: "stay", id: stayId, amount: String(amount), currency: cur, fee: String(fee), amount_cur: ((lines.reduce((t, l) => t + Math.round(l.amount * rate * 100), 0) + (fee > 0 ? Math.round(fee * rate * 100) : 0)) / 100).toFixed(2) })) { p.set(`metadata[${k}]`, v); p.set(`payment_intent_data[metadata][${k}]`, v); }
  const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST", headers: { Authorization: `Bearer ${keyFor(cur)}`, "Content-Type": "application/x-www-form-urlencoded", "Stripe-Version": "2024-06-20" }, body: p,
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
        extras: (R.extras || []).filter((e) => !(e as { off?: boolean }).off).map((e) => ({ id: e.id, cat: (e as { cat?: string }).cat ?? "misc", name: e.name, kind: e.kind, price: e.price ?? null, tiers: e.tiers ?? null, addon: e.addon ?? null, options: e.options ?? null, any: e.any ?? false, any_max: e.any_max ?? null, max: e.max ?? null, unit: e.unit ?? null, note: e.note ?? "" })),
        map: R.map?.img ? { img: R.map.img, pins: R.map.pins || {} } : null,
        offer: await offer(),
        fx: await fx(),
        ...(await cardRule().then((r) => ({ card_pct: r.pct, card_fixed: r.fixed, card_fixed_under: r.under }))),
      });
    }
    if (body.mode === "quote") {
      const bad = checkDates(body.from, body.to); if (bad) return json({ error: bad });
      const from = body.from as string, to = body.to as string;
      const taken = await takenRooms(from, to), rooms = await roomsOn(), O = await offer();
      const out = rooms.map((r) => {
        const g = R.groups.find((x) => x.rooms.includes(r.id));
        if (!g) return { id: r.id, state: "off" };
        if (taken.has(r.id)) return { id: r.id, group: g.id, state: "taken" };
        const q = quote(R, g, from, to);
        return q.missing ? { id: r.id, group: g.id, state: "off" } : { id: r.id, group: g.id, state: "free", total: offPrice(q.total, O), full: q.total, nights: q.nights };
      });
      return json({ from, to, nights: Math.round((Date.parse(to) - Date.parse(from)) / 864e5), rooms: out });
    }
    if (body.mode === "reserve") {
      const pp = body.pay === "pp";
      if (!KEY && !pp) return json({ error: "Card payments are not set up yet. Message us to book." });
      const cur = CURS.includes(String(body.currency ?? "thb").toLowerCase()) ? String(body.currency ?? "thb").toLowerCase() : "thb";
      if (pp && cur !== "thb") return json({ error: "Thai QR is in Thai baht only. Choose Thai baht, or pay by card." });
      const acc = pp ? (await admin.rpc("web_stay_promptpay")).data as { payload?: string; name?: string } | null : null;
      if (pp && !acc?.payload) return json({ error: "Thai QR is not set up yet. Pay by card, or WhatsApp us." });
      const FX = await fx(), rate = FX[cur];
      if (!rate) return json({ error: "Paying in that currency is not available right now. Choose Thai baht." });
      const bad = checkDates(body.from, body.to); if (bad) return json({ error: bad });
      const from = body.from as string, to = body.to as string, roomId = String(body.room_id ?? "");
      const g = R.groups.find((x) => x.rooms.includes(roomId)); if (!g) return json({ error: "That room can not be booked online." });
      const q = quote(R, g, from, to); if (q.missing || !(q.total >= 20)) return json({ error: "That room has no price for those dates. Message us." });
      // the direct booking discount is taken off the room price; long stays get the gift (noted on the stay for the front desk)
      const O = await offer(), full = q.total, nightsN = Math.round((Date.parse(to) - Date.parse(from)) / 864e5);
      q.total = offPrice(full, O);
      const offerNote = [O.pct > 0 && q.total < full ? `Book direct ${O.pct}% off (full price ${full} THB).` : "", O.gift && O.gift_nights && nightsN >= O.gift_nights ? `Gift: ${O.gift} (${nightsN} nights).` : ""].filter(Boolean).join(" ");
      const { data: rm } = await admin.from("rooms").select("name").eq("id", roomId).maybeSingle();
      const items = extraItems(R, body.extras, from, to), total = q.total + items.reduce((t, i) => t + i.price, 0);
      await admin.rpc("web_holds_cleanup");
      const { data, error } = await admin.rpc("web_reserve", { p_room: roomId, p_from: from, p_to: to, p_price: q.total, p_name: String(body.name ?? ""), p_email: String(body.email ?? ""),
        p_phone: String(body.phone ?? ""), p_guests: String(body.guests ?? ""), p_note: [String(body.note ?? "").slice(0, 400), offerNote].filter(Boolean).join("\n") });
      if (error) return json({ error: error.message });
      const stayId = (data as { stay_id: string }).stay_id;
      if (body.ref && /^[a-z0-9-]{2,30}$/i.test(String(body.ref))) await admin.rpc("affiliate_tag_stay", { p_stay: stayId, p_code: String(body.ref) });
      try {
        if (items.length) { const { error: ie } = await admin.rpc("web_add_items", { p_stay: stayId, p_items: items }); if (ie) throw new Error(ie.message); }
        if (pp) return json({ pp: acc, stay_id: stayId, total, what: `Pangea Resort, ${rm?.name ?? "room"}, ${from} to ${to}` });
        const lines = [{ name: `Pangea Resort, ${rm?.name ?? "room"}, ${from} to ${to}${q.total < full ? `, book direct ${O.pct}% off` : ""}`, amount: q.total }].concat(items.map((i) => ({ name: i.name, amount: i.price })));
        const url = await stripeSession(lines, total, stayId, (data as { email: string }).email, backUrl(body.back), cur, rate, body.pay === "qr" && cur === "thb");
        return json({ url, stay_id: stayId, total });
      } catch (e) {
        await admin.from("stays").update({ status: "cancelled", hold_until: null, notes: "Website booking, card payment could not start." }).eq("id", stayId);
        await admin.from("purchases").update({ cancelled: true }).eq("for_stay", stayId).eq("ordered_in_app", true);
        return json({ error: "Card payment could not start. Try again, or message us. " + (e as Error).message });
      }
    }
    if (body.mode === "claim") {
      if (!/^[0-9a-f-]{36}$/.test(String(body.ref ?? ""))) return json({ error: "Not found." });
      const { data, error } = await admin.rpc("web_stay_claim", { p_stay: body.ref });
      if (error) return json({ error: error.message });
      return json(data);
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
