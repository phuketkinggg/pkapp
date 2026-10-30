// The public "Book your stay" page talks to this. No sign in.
// info:    rooms, price groups, seasons and the map (no guest details, ever)
// quote:   which rooms are free for some dates, and the price for each
// reserve: hold a room for 30 minutes and open a Stripe card payment for it (with the website offer: direct booking discount, gift for long stays)
// reserve with pay:"pp": Thai QR (PromptPay) straight to our bank: returns the QR instead of a Stripe page
// claim:   the guest tapped "I have paid": the room is held 12 hours and the desk checks the bank
// status:  after paying, the page asks if the booking went through
// followups: (the database, every 15 minutes, with the sync token) a friendly email to guests who started paying but did not finish
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
type Group = { id: string; name: string; rooms: string[]; prices: Record<string, number>; note?: string; month?: number; months?: Record<string, number> };
type Opt = { id: string; name: string; price: number; limit?: number };
type Extra = { id: string; name: string; kind: "pick" | "day" | "qty"; price?: number; covers?: string[]; per_day?: number; tiers?: { max: number; price: number }[]; addon?: { name: string; price: number }; options?: Opt[]; any?: boolean; any_max?: number; max?: number; unit?: string; note?: string };
type Rates = { base: string; month_nights?: number; seasons: Season[]; groups: Group[]; extras?: Extra[]; map?: { img?: string; pins?: Record<string, { x: number; y: number }> } };
type Item = { name: string; price: number; covers: string[]; limit?: number | null; days?: number | null; starts?: string | null; expires?: string | null; course_id?: string };
// the online course on offer (Courses, Offer it), added to a stay as an extra; checked and priced by the database
async function courseOffer() { try { const { data } = await admin.rpc("course_offer"); return data && (data as { id?: string }).id ? data : null; } catch { return null; } }
async function courseItem(body: Record<string, unknown>, items: Item[], from: string, to: string): Promise<Item | null> {
  if (!body.course) return null;
  const training = items.some((i) => (i.covers || []).includes("Muay Thai"));
  const { data, error } = await admin.rpc("web_course_item", { p_course: String(body.course), p_email: String(body.email ?? ""), p_training: training });
  if (error) throw new Error(error.message);
  const c = data as { course_id: string; price: number; name: string } | null; if (!c) return null;
  return { name: c.name, price: c.price, covers: [], course_id: c.course_id, starts: from, expires: addDays(to, 365) };
}

async function rates(): Promise<Rates> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "room_rates").maybeSingle();
  try { const r = JSON.parse(data?.value ?? "{}"); return { base: r.base || "low", month_nights: r.month_nights, seasons: r.seasons || [], groups: r.groups || [], extras: r.extras || [], map: r.map || {} }; }
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
// deposit: from "nights" nights the guest can pay part now (pct % of the room, high_pct % when they arrive in a busier season, never less than min_nights nights),
// extras in full; the rest is due balance_days days before arrival. Monthly price stays pay at least the first month.
type Deposit = { on: boolean; nights: number; pct: number; high_pct: number; min_nights: number; balance_days: number };
type Promo = { name: string; from: string; to: string; pct: number };
type Offer = { on: boolean; pct: number; gift_nights: number; gift: string; includes: string; month_banner: string; all_include: string; deposit: Deposit; quote: boolean; promos: Promo[] };
async function offer(): Promise<Offer> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "stay_offer").maybeSingle();
  let j: Record<string, unknown> = {}; try { j = JSON.parse(data?.value ?? "{}"); } catch { /* none */ }
  const on = j.on === true, pct = Math.max(0, Math.min(50, Number(j.pct) || 0)), gn = Math.max(0, Math.min(90, Math.round(Number(j.gift_nights) || 0)));
  // includes: what every room comes with (for example unlimited group classes for 1 person), shown on each room; not part of the offer switch
  return { on, pct: on ? pct : 0, gift_nights: on && String(j.gift ?? "").trim() ? gn : 0, gift: on ? String(j.gift ?? "").trim().slice(0, 80) : "", includes: String(j.includes ?? "").trim().slice(0, 120),
    // the monthly banner at the top of the booking page (shown when a price group has a monthly price); not part of the offer switch
    month_banner: String(j.month_banner ?? "").trim().slice(0, 80), all_include: String(j.all_include ?? "").trim().slice(0, 120),
    // the deposit and "email me this price" are not part of the offer switch
    deposit: { on: j.dep_on === true, nights: clampN(j.dep_nights, 14, 1, 90), pct: clampN(j.dep_pct, 30, 5, 95), high_pct: clampN(j.dep_high_pct, 50, 5, 95),
      min_nights: clampN(j.dep_min_nights, 7, 0, 60), balance_days: clampN(j.dep_balance_days, 14, 0, 90) },
    quote: j.quote_on !== false,
    // dated offers (Settings, Website offer, Offers for dates): nights between from and to get their own % off instead of the book direct discount.
    // Shown on the booking page until they end. Not part of the offer switch.
    promos: (Array.isArray(j.promos) ? j.promos : []).map((x: Record<string, unknown>) => ({ name: String(x.name ?? "").trim().slice(0, 60), from: String(x.from ?? ""), to: String(x.to ?? ""), pct: Math.max(0, Math.min(80, Math.round(Number(x.pct) || 0))) }))
      .filter((x: Promo) => isDay(x.from) && isDay(x.to) && x.to >= x.from && x.to >= today()) };
}
// the % off for one night: a dated offer for that night (the biggest when several), else the book direct discount
function pctAt(O: Offer, day: string): { pct: number; promo: Promo | null } {
  let best: Promo | null = null; for (const p of O.promos) if (day >= p.from && day <= p.to && (!best || p.pct > best.pct)) best = p;
  return best ? { pct: best.pct, promo: best } : { pct: O.pct, promo: null };
}
const clampN = (v: unknown, d: number, lo: number, hi: number) => { const x = Math.round(Number(v)); return v != null && v !== "" && Number.isFinite(x) ? Math.max(lo, Math.min(hi, x)) : d; };
// the part paid now when the guest picks the deposit (null: pay the whole stay). Same sum as book.html.
function depositPlan(R: Rates, O: Offer, from: string, nights: number, room: number, extras: number, monthly: boolean) {
  const D = O.deposit; if (!D.on || nights < D.nights || !(room > 0)) return null;
  const due = monthly ? addDays(from, monthNights(R) - 7) : addDays(from, -D.balance_days);
  if (!monthly && due <= addDays(today(), 2)) return null;
  const s = seasonOf(R, from), high = !!s && s.id !== R.base;
  let dep = Math.max(room * (high ? D.high_pct : D.pct) / 100, room * Math.min(D.min_nights, nights) / nights);
  if (monthly) dep = Math.max(dep, room * Math.min(monthNights(R), nights) / nights);
  const total = room + extras, now = Math.min(total, Math.ceil((dep + extras) / 100) * 100);
  if (now >= total * 0.85) return null;
  return { now, rest: total - now, due, monthly };
}
async function bizStay(): Promise<string> {
  const { data } = await admin.from("app_settings").select("value").eq("key", "acc_names").maybeSingle();
  try { return String(JSON.parse(data?.value ?? "{}").stay || "").trim() || "Our resort"; } catch { return "Our resort"; }
}
// the room with the offer taken off night by night, and the dated offer used (for the label)
function offPrice(nights: { day: string; price: number }[], O: Offer) {
  let total = 0, promo: Promo | null = null;
  for (const n of nights) { const a = pctAt(O, n.day); total += a.pct > 0 ? n.price * (100 - a.pct) / 100 : n.price; if (a.promo && a.pct > 0 && (!promo || a.pct > promo.pct)) promo = a.promo; }
  return { total: Math.round(total), promo };
}
// long stays: a price group can have a monthly price (Room prices). A month is month_nights nights (28 unless set): that many nights cost the
// monthly price, and each night after costs that share of it (a 28th for a 28 night month). It is used only when it is cheaper than the nightly price with the offer.
const monthNights = (R: Rates) => Math.max(7, Math.min(90, Math.round(Number(R.month_nights) || 28)));
// shorter stays never cost more than the monthly price either
// a price group can have a monthly price for each season (months), else one for the whole year (month). A stay across seasons
// uses each night's season: the month price is the average of the nights, rounded to 10 THB.
function monthRate(R: Rates, g: Group, day: string) {
  const s = seasonOf(R, day), v = s && g.months ? Number(g.months[s.id]) : NaN;
  return v >= 1000 ? v : Number(g.month) >= 1000 ? Number(g.month) : NaN;
}
function lowestMonth(g: Group) {
  const l = [Number(g.month), ...Object.values(g.months || {}).map(Number)].filter((v) => v >= 1000);
  return l.length ? Math.min(...l) : null;
}
function monthTotal(R: Rates, g: Group, days: string[]): { total: number; month: number } | null {
  if (!days.length) return null; let sum = 0;
  for (const d of days) { const v = monthRate(R, g, d); if (isNaN(v)) return null; sum += v; }
  const avg = sum / days.length, month = Math.round(avg / 10) * 10;
  return { month, total: days.length <= monthNights(R) ? month : Math.round(avg * days.length / monthNights(R) / 10) * 10 };
}
// the price a guest pays for the room: the cheaper of the nightly price with the website offer, and the monthly price
function roomPrice(R: Rates, g: Group, nights: { day: string; price: number }[], O: Offer) {
  const off = offPrice(nights, O), mt = monthTotal(R, g, nights.map((n) => n.day));
  return mt != null && mt.total < off.total ? { total: mt.total, monthly: true, month: mt.month, promo: null as Promo | null } : { total: off.total, monthly: false, month: null as number | null, promo: off.promo };
}
const offLabel = (rp: { promo: Promo | null }, O: Offer) => rp.promo ? `${rp.promo.name || "Special offer"} ${rp.promo.pct}% off` : `Book direct ${O.pct}% off`;
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

// "Email me this price": the guest gets the price for the room and dates they looked at, with a link back to book it.
// The front desk gets a notice to follow up. Priced here from the settings, never from the page.
const RESEND = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
const escH = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const T = (n: number) => Math.round(n).toLocaleString("en-US") + " THB";
const dayW = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
async function mailQuote(R: Rates, body: Record<string, unknown>) {
  const O = await offer(); if (!O.quote) return json({ error: "Not available." });
  const email = String(body.email ?? "").trim().toLowerCase(), name = String(body.name ?? "").trim().slice(0, 80);
  if (!/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/.test(email) || email.length > 120) return json({ error: "Type a real email address." });
  const bad = checkDates(body.from, body.to); if (bad) return json({ error: bad });
  const from = body.from as string, to = body.to as string, roomId = String(body.room_id ?? "");
  const g = R.groups.find((x) => x.rooms.includes(roomId)); if (!g) return json({ error: "Pick a room first." });
  const q = quote(R, g, from, to); if (q.missing) return json({ error: "That room has no price for those dates. Message us." });
  const since = (h: number) => new Date(Date.now() - h * 3600e3).toISOString();
  const { count: mine } = await admin.from("sent_emails").select("id", { count: "exact", head: true }).eq("campaign", "stay_quote").eq("to_email", email).gte("created_at", since(24));
  const { count: all } = await admin.from("sent_emails").select("id", { count: "exact", head: true }).eq("campaign", "stay_quote").gte("created_at", since(1));
  if ((mine ?? 0) >= 3 || (all ?? 0) >= 30) return json({ error: "We already sent you a price. Check your inbox, or WhatsApp us." });
  if (!RESEND) return json({ error: "Email is not set up. WhatsApp us for a price." });
  const nights = q.nights.length, rp = roomPrice(R, g, q.nights, O), items = extraItems(R, body.extras, from, to);
  try { const ci = await courseItem(body, items, from, to); if (ci) items.push(ci); } catch (e) { return json({ error: (e as Error).message }); }
  const total = rp.total + items.reduce((t, i) => t + i.price, 0), plan = depositPlan(R, O, from, nights, rp.total, total - rp.total, rp.monthly);
  const { data: rm } = await admin.from("rooms").select("name").eq("id", roomId).maybeSingle();
  const STAY = await bizStay(), roomName = rm?.name ?? "Room";
  const link = backUrl(body.back) + `?from=${from}&to=${to}&room=${encodeURIComponent(roomId)}`;
  const { data: ms } = await admin.from("app_settings").select("value").eq("key", "mail_from").maybeSingle();
  let mf: { from?: string; reply_to?: string; whatsapp?: string } = {}; try { mf = JSON.parse(ms?.value ?? "{}"); } catch { /* defaults */ }
  const wa = String(mf.whatsapp ?? "66969076150").replace(/\D/g, "");
  const lines: [string, string][] = [[`${roomName}, ${nights} night${nights === 1 ? "" : "s"}`, T(rp.total)]];
  if (rp.monthly) lines.push(["Monthly price", `${T(Number(rp.month))} a month`]); else if (rp.total < q.total) lines.push([offLabel(rp, O), `you save ${T(q.total - rp.total)}`]);
  items.forEach((i) => lines.push([i.name, T(i.price)]));
  if (O.gift && O.gift_nights && nights >= O.gift_nights) lines.push([O.gift.charAt(0).toUpperCase() + O.gift.slice(1), "Free"]);
  const notes = [O.includes, plan ? `Book with a deposit of ${T(plan.now)}, then ${T(plan.rest)} ${plan.monthly ? "month by month, each month 7 days before it starts" : "by " + dayW(plan.due)}.` : ""].filter(Boolean);
  const hi = name ? name.split(/\s+/)[0] : "there";
  const subject = `Your price at ${STAY}: ${dayW(from)} to ${dayW(to)}`;
  const text = [`Hi ${hi},`, "", `Here is your price at ${STAY}, ${dayW(from)} to ${dayW(to)}.`, "", ...lines.map((l) => `${l[0]}: ${l[1]}`), `Total: ${T(total)}`, "", ...notes,
    "", "Rooms go quickly and prices can change. Book it here:", link, "", `Questions? Reply to this email, or WhatsApp us: https://wa.me/${wa}`].join("\n");
  const G = "#1a3325", INK = "#22201c", MUT = "#6b665c";
  const html = `<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;color:${INK};line-height:1.5"><p>Hi ${escH(hi)},</p><p>Here is your price at <b>${escH(STAY)}</b>, ${escH(dayW(from))} to ${escH(dayW(to))}.</p>
<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse">${lines.map((l) => `<tr><td style="padding:8px 0;border-bottom:1px solid #e6dfd2">${escH(l[0])}</td><td align="right" style="padding:8px 0;border-bottom:1px solid #e6dfd2;white-space:nowrap">${escH(l[1])}</td></tr>`).join("")}
<tr><td style="padding:10px 0"><b>Total</b></td><td align="right" style="padding:10px 0"><b>${escH(T(total))}</b></td></tr></table>
${notes.map((n) => `<p style="color:${MUT};margin:6px 0">${escH(n)}</p>`).join("")}
<p style="margin:22px 0"><a href="${escH(link)}" style="background:${G};color:#fff;padding:12px 22px;border-radius:8px;text-decoration:none;font-weight:bold">Book this room</a></p>
<p style="color:${MUT}">Rooms go quickly and prices can change. Questions? Reply to this email, or <a href="https://wa.me/${wa}">WhatsApp us</a>.</p></div>`;
  let ok = false, err: string | null = null, rid: string | null = null;
  try {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: mf.from || `${STAY} <hello@app.phuketking.com>`, to: [email], reply_to: mf.reply_to || "hello@phuketking.com", subject, html, text }) });
    const j = await r.json().catch(() => ({})); if (r.ok) { ok = true; rid = j?.id ?? null; } else err = j?.message || `Email service said ${r.status}`;
  } catch (e) { err = (e as Error).message; }
  await admin.from("sent_emails").insert({ to_email: email, to_name: name || null, subject, body: text, status: ok ? "sent" : "failed", error: err, resend_id: rid, sent_at: ok ? new Date().toISOString() : null, campaign: "stay_quote" });
  if (!ok) return json({ error: "The email could not be sent. WhatsApp us for your price." });
  const phone = String(body.phone ?? "").trim().slice(0, 30);
  await admin.from("notices").insert({ kind: "stay", title: `Price sent: ${name || email}, ${roomName}`,
    detail: `${dayW(from)} to ${dayW(to)}, ${nights} nights, ${T(total)}. ${email}${phone ? ", " + phone : ""}. They have not booked yet: follow up in a day or two.` });
  return json({ ok: true });
}

// unpaid website bookings: about an hour later the guest gets their stay and a link to finish it, in a friendly tone
async function followups(req: Request) {
  const { data: ok } = await admin.rpc("sync_token_ok", { p_token: req.headers.get("x-sync-token") ?? "" });
  if (ok !== true) return json({ error: "Not allowed." }, 401);
  if (!RESEND) return json({ error: "Email is not set up." });
  const { data } = await admin.rpc("web_followups_due");
  const due = (data ?? []) as { id: string; name: string; email: string; room_id: string; room: string; from: string; to: string; room_price: number; extras: { name: string; price: number }[] }[];
  if (!due.length) return json({ ok: true, sent: 0 });
  const O = await offer(), STAY = await bizStay();
  const { data: so } = await admin.from("app_settings").select("value").eq("key", "stay_offer").maybeSingle();
  let sj: { book_url?: string } = {}; try { sj = JSON.parse(so?.value ?? "{}"); } catch { /* defaults */ }
  const base = /^https:\/\/[^\s]+$/.test(String(sj.book_url ?? "")) ? String(sj.book_url) : "https://www.phuketking.com/book";
  const { data: ms } = await admin.from("app_settings").select("value").eq("key", "mail_from").maybeSingle();
  let mf: { from?: string; reply_to?: string; whatsapp?: string } = {}; try { mf = JSON.parse(ms?.value ?? "{}"); } catch { /* defaults */ }
  const wa = String(mf.whatsapp ?? "66969076150").replace(/\D/g, "");
  let sent = 0;
  for (const g of due.slice(0, 20)) {
    const nights = Math.round((Date.parse(g.to) - Date.parse(g.from)) / 864e5), hi = g.name ? g.name.split(/\s+/)[0] : "there";
    const total = Number(g.room_price || 0) + (g.extras || []).reduce((t, x) => t + Number(x.price || 0), 0);
    const link = base + (base.includes("?") ? "&" : "?") + `from=${g.from}&to=${g.to}&room=${encodeURIComponent(g.room_id)}`;
    const lines: [string, string][] = [[`${g.room || "Your room"}, ${nights} night${nights === 1 ? "" : "s"}`, T(Number(g.room_price || 0))], ...(g.extras || []).map((x) => [x.name, T(Number(x.price || 0))] as [string, string])];
    const dep = O.deposit.on && nights >= O.deposit.nights;
    const subject = `Your stay at ${STAY}, ${dayW(g.from)} to ${dayW(g.to)}`;
    const paras = [
      `We saw you started booking a stay with us, but the payment did not go through. No worries, that happens a lot, especially with bigger card payments from abroad that some banks stop for a moment.`,
      `Here is what you chose, so you do not have to start again. The room is not held yet, so book it when you are ready:`,
    ];
    const after = [
      dep ? `You can also pay a deposit now and the rest closer to your arrival. Just choose the deposit on the booking page.` : "",
      `And if you have any questions, about the stay, the training, the food or anything else, just reply to this email or message us on WhatsApp. Whether you stay with us or not, we are always happy to help.`,
    ].filter(Boolean);
    const text = [`Hi ${hi},`, "", ...paras, "", ...lines.map((l) => `${l[0]}: ${l[1]}`), `Total: ${T(total)}`, "", "Finish your booking: " + link, "", ...after, "", `WhatsApp: https://wa.me/${wa}`, "", `Have a great day,`, `The ${STAY} team`].join("\n");
    const G = "#1a3325", INK = "#22201c", MUT = "#6b665c";
    const html = `<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;color:${INK};line-height:1.55"><p>Hi ${escH(hi)},</p>${paras.map((p) => `<p>${escH(p)}</p>`).join("")}
<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse">${lines.map((l) => `<tr><td style="padding:8px 0;border-bottom:1px solid #e6dfd2">${escH(l[0])}</td><td align="right" style="padding:8px 0;border-bottom:1px solid #e6dfd2;white-space:nowrap">${escH(l[1])}</td></tr>`).join("")}
<tr><td style="padding:10px 0"><b>Total</b></td><td align="right" style="padding:10px 0"><b>${escH(T(total))}</b></td></tr></table>
<p style="margin:22px 0"><a href="${escH(link)}" style="background:${G};color:#fff;padding:12px 22px;border-radius:8px;text-decoration:none;font-weight:bold">Finish my booking</a></p>
${after.map((p) => `<p>${escH(p)}</p>`).join("")}<p><a href="https://wa.me/${wa}">Message us on WhatsApp</a></p><p>Have a great day,<br>The ${escH(STAY)} team</p>
<p style="color:${MUT};font-size:12px;margin-top:22px">You get this one email because you started a booking on our website. We will not send more about it.</p></div>`;
    let okm = false, err: string | null = null, rid: string | null = null;
    try {
      const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: mf.from || `${STAY} <hello@app.phuketking.com>`, to: [g.email], reply_to: mf.reply_to || "hello@phuketking.com", subject, html, text }) });
      const j = await r.json().catch(() => ({})); if (r.ok) { okm = true; rid = j?.id ?? null; } else err = j?.message || `Email service said ${r.status}`;
    } catch (e) { err = (e as Error).message; }
    await admin.from("sent_emails").insert({ to_email: g.email, to_name: g.name || null, subject, body: text, status: okm ? "sent" : "failed", error: err, resend_id: rid, sent_at: okm ? new Date().toISOString() : null, campaign: "stay_followup" });
    await admin.rpc("web_followup_mark", { p_stay: g.id });
    if (okm) sent++;
  }
  return json({ ok: true, sent });
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
        groups: R.groups.map((g) => ({ id: g.id, name: g.name, note: g.note || "", prices: g.prices, month: lowestMonth(g) })),
        month_nights: monthNights(R),
        rooms: rooms.map((r) => ({ id: r.id, name: r.name, group: inGroup(r.id)?.id ?? null })),
        extras: (R.extras || []).filter((e) => !(e as { off?: boolean }).off).map((e) => ({ id: e.id, cat: (e as { cat?: string }).cat ?? "misc", name: e.name, kind: e.kind, price: e.price ?? null, tiers: e.tiers ?? null, addon: e.addon ?? null, options: e.options ?? null, any: e.any ?? false, any_max: e.any_max ?? null, max: e.max ?? null, unit: e.unit ?? null, note: e.note ?? "" })),
        map: R.map?.img ? { img: R.map.img, pins: R.map.pins || {} } : null,
        offer: await offer(),
        course: await courseOffer(),
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
        if (q.missing) return { id: r.id, group: g.id, state: "off" };
        const rp = roomPrice(R, g, q.nights, O);
        return { id: r.id, group: g.id, state: "free", total: rp.total, full: q.total, monthly: rp.monthly, month: rp.monthly ? rp.month : null, promo: rp.promo?.name || (rp.promo ? "Special offer" : null), nights: q.nights };
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
      const rp = roomPrice(R, g, q.nights, O); q.total = rp.total;
      const offerNote = [rp.monthly ? `Monthly price ${rp.month} THB a month (full price ${full} THB).` : q.total < full ? `${offLabel(rp, O)} (full price ${full} THB).` : "", O.gift && O.gift_nights && nightsN >= O.gift_nights ? `Gift: ${O.gift} (${nightsN} nights).` : ""].filter(Boolean).join(" ");
      const { data: rm } = await admin.from("rooms").select("name").eq("id", roomId).maybeSingle();
      const items = extraItems(R, body.extras, from, to);
      try { const ci = await courseItem(body, items, from, to); if (ci) items.push(ci); } catch (e) { return json({ error: (e as Error).message }); }
      const total = q.total + items.reduce((t, i) => t + i.price, 0);
      const plan = body.deposit ? depositPlan(R, O, from, nightsN, q.total, total - q.total, rp.monthly) : null;
      if (body.deposit && !plan) return json({ error: "A deposit is not available for this stay. Pay the whole stay, or WhatsApp us." });
      const payNow = plan ? plan.now : total, STAY = await bizStay();
      const depNote = plan ? `Website deposit ${plan.now} THB of ${total} THB. ${plan.rest} THB left, ${plan.monthly ? "month by month, each month 7 days before it starts" : "due by " + plan.due}.` : "";
      await admin.rpc("web_holds_cleanup");
      const { data, error } = await admin.rpc("web_reserve", { p_room: roomId, p_from: from, p_to: to, p_price: q.total, p_name: String(body.name ?? ""), p_email: String(body.email ?? ""),
        p_phone: String(body.phone ?? ""), p_guests: String(body.guests ?? ""), p_note: [String(body.note ?? "").slice(0, 400), offerNote, depNote].filter(Boolean).join("\n") });
      if (error) return json({ error: error.message });
      const stayId = (data as { stay_id: string }).stay_id;
      if (body.ref && /^[a-z0-9-]{2,30}$/i.test(String(body.ref))) await admin.rpc("affiliate_tag_stay", { p_stay: stayId, p_code: String(body.ref), p_at: isNaN(Date.parse(String(body.ref_at ?? ""))) ? null : new Date(String(body.ref_at)).toISOString() });
      try {
        if (items.length) { const { error: ie } = await admin.rpc("web_add_items", { p_stay: stayId, p_items: items }); if (ie) throw new Error(ie.message); }
        if (plan) { const { error: de } = await admin.from("stays").update({ web_pay_now_thb: plan.now }).eq("id", stayId); if (de) throw new Error(de.message); }
        if (pp) return json({ pp: acc, stay_id: stayId, total: payNow, all: total, deposit: !!plan, what: `${plan ? "Deposit: " : ""}${STAY}, ${rm?.name ?? "room"}, ${from} to ${to}` });
        const lines = plan
          ? [{ name: `Deposit: ${STAY}, ${rm?.name ?? "room"}, ${from} to ${to} (rest ${plan.rest.toLocaleString("en-US")} THB${plan.monthly ? " monthly" : " by " + plan.due})`, amount: plan.now }]
          : [{ name: `${STAY}, ${rm?.name ?? "room"}, ${from} to ${to}${rp.monthly ? ", monthly price" : q.total < full ? `, ${offLabel(rp, O).toLowerCase()}` : ""}`, amount: q.total }].concat(items.map((i) => ({ name: i.name, amount: i.price })));
        const url = await stripeSession(lines, payNow, stayId, (data as { email: string }).email, backUrl(body.back), cur, rate, body.pay === "qr" && cur === "thb");
        return json({ url, stay_id: stayId, total: payNow, all: total, deposit: !!plan });
      } catch (e) {
        await admin.from("stays").update({ status: "cancelled", hold_until: null, notes: "Website booking, card payment could not start." }).eq("id", stayId);
        await admin.from("purchases").update({ cancelled: true }).eq("for_stay", stayId).eq("ordered_in_app", true);
        return json({ error: "Card payment could not start. Try again, or message us. " + (e as Error).message });
      }
    }
    if (body.mode === "mail_quote") return await mailQuote(R, body);
    if (body.mode === "followups") { await admin.rpc("web_holds_cleanup"); return await followups(req); }
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
