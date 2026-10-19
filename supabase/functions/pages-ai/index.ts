// AI web page maker for the Phuket King website. A manager describes the page; Claude writes it as sections the website knows how to show.
// POST {mode:'make', brief, images?, library?}                 a new page: {title, slug, description, sections}
// POST {mode:'edit', page, ask, images?, library?}             the same page changed as asked
// Only managers. Secret: ANTHROPIC_API_KEY
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = () => (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
const MODEL = "claude-sonnet-5-5";
const IMG = URL_ + "/storage/v1/object/public/promos/";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const tidy = (s: unknown) => String(s ?? "").replace(/\s*[—–]\s*/g, ", ").replace(/\s&\s/g, " and ").replace(/,\s*,/g, ",").trim();

const SCHEMA = `A page is JSON: {"title": "...", "slug": "small-letters-and-dashes", "description": "one sentence for Google, under 155 characters", "sections": [ ... ]}
Each section has "type" and "bg" ("dark" charcoal, "light" cream or "navy"; alternate them so the page has rhythm, the hero has no bg). Section types and their fields:
- {"type":"hero","heading","text","image","button_text","button_link"}  big photo at the top. Use exactly one, first.
- {"type":"text","eyebrow","heading","body"}  a block of writing.
- {"type":"split","eyebrow","heading","body","image","image_side":"left"|"right","button_text","button_link"}  photo beside text. Alternate sides.
- {"type":"cards","eyebrow","heading","intro","items":[{"title","text","image"}]}  3 or 4 cards (image optional).
- {"type":"steps","eyebrow","heading","items":[{"title","text"}]}  numbered steps, for how something works.
- {"type":"gallery","heading","images":["url", ...]}  3 to 8 photos.
- {"type":"quote","text","name"}  a short testimonial. Only use real words the gym gave you, never invent a quote.
- {"type":"faq","heading","items":[{"q","a"}]}
- {"type":"video","heading","url"}  only a YouTube link the gym gave you.
- {"type":"cta","heading","text","button_text","button_link"}  closing call to action. End most pages with one.
"body", "text", "intro" and FAQ answers can use simple formatting: a blank line for a new paragraph, "- " for list items, **bold**.
"eyebrow" is a short label above a heading, 1 to 3 words.
Links ("button_link"): use "whatsapp" to open WhatsApp with the gym, or one of these site pages: prices.html, book.html (stay at Pangea Resort), index.html#schedule, about.html, wellness.html, dtv.html, courses.html, shop.html, blog.html, or a full https:// link the gym gave you.
Images: only use URLs from the photo list or the photos the gym attached. Never invent an image URL. Leave "image" empty ("") if nothing fits.`;

const VOICE = `You build web pages for Phuket King Muay Thai (PKMT), a Muay Thai gym in Kathu, Phuket, Thailand. Website phuketking.com.
Facts you may use: known for technical coaching, beginners to fighters. Tagline "Work hard, Fight easy". New lakeside site with a ring, heavy bags, a free weight zone, a recovery area (herbal steam room, dry sauna, ice bath, yoga), Pangea Resort lakeside bungalows on site, Pangea Cafe with healthy, seed-oil-free food. Group classes Monday to Saturday. International guests, many staying weeks or months, some on a DTV visa.
Voice: warm, confident, clear, real. Short sentences. Benefits first. No hype words like "ultimate" or "world-class".
Hard rules:
- Never use a long dash (em dash or en dash). Use a comma, a full stop or a new line.
- Never use the & sign. Write "and".
- Never invent prices, dates, times, names, numbers, awards, offers or reviews. Use only what the gym tells you. If a price matters, link to prices.html instead.
- British spelling is fine. Write for a phone screen.
${SCHEMA}
Reply with the JSON only, no other text.`;

async function manager(req: Request) {
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const { data } = await user.auth.getUser();
  if (!data?.user) return false;
  const { data: s } = await admin.from("staff").select("role").eq("user_id", data.user.id).eq("active", true).maybeSingle();
  return s?.role === "manager";
}

const TYPES = ["hero", "text", "split", "cards", "steps", "gallery", "quote", "faq", "video", "cta"];
function okImg(u: unknown, allowed: Set<string>) { const s = String(u ?? ""); return s && (s.startsWith(IMG) || allowed.has(s)) && s.startsWith("https://") ? s : ""; }
function okLink(u: unknown) { const s = String(u ?? "").trim(); return /^(whatsapp|https:\/\/\S+|[a-z0-9-]+\.html(#[a-z0-9-]+)?|#[a-z0-9-]+)$/i.test(s) ? s : ""; }
// keep only what the website can show, and apply the house style to every text
function clean(p: Record<string, unknown>, allowed: Set<string>) {
  const t = (x: unknown, n: number) => tidy(x).slice(0, n);
  const secs = (Array.isArray(p.sections) ? p.sections : []).slice(0, 30).map((s0) => {
    const s = (s0 ?? {}) as Record<string, unknown>; const type = String(s.type ?? "");
    if (!TYPES.includes(type)) return null;
    const o: Record<string, unknown> = { type, id: "s" + crypto.randomUUID().slice(0, 8) };
    if (type !== "hero") o.bg = ["dark", "light", "navy"].includes(String(s.bg)) ? s.bg : "dark";
    for (const k of ["eyebrow", "heading", "button_text", "name"]) if (s[k] != null) o[k] = t(s[k], 160);
    for (const k of ["text", "body", "intro"]) if (s[k] != null) o[k] = t(s[k], 6000);
    if (s.image != null) o.image = okImg(s.image, allowed);
    if (s.button_link != null) o.button_link = okLink(s.button_link);
    if (type === "split") o.image_side = s.image_side === "left" ? "left" : "right";
    if (type === "video") o.url = /^https:\/\/(www\.)?(youtube\.com|youtu\.be)\//.test(String(s.url ?? "")) ? String(s.url) : "";
    if (type === "gallery") o.images = (Array.isArray(s.images) ? s.images : []).map((u) => okImg(u, allowed)).filter(Boolean).slice(0, 12);
    if (["cards", "steps"].includes(type)) o.items = (Array.isArray(s.items) ? s.items : []).slice(0, 8).map((i0) => { const i = (i0 ?? {}) as Record<string, unknown>;
      return { title: t(i.title, 120), text: t(i.text, 1200), ...(type === "cards" ? { image: okImg(i.image, allowed) } : {}) }; });
    if (type === "faq") o.items = (Array.isArray(s.items) ? s.items : []).slice(0, 20).map((i0) => { const i = (i0 ?? {}) as Record<string, unknown>; return { q: t(i.q, 200), a: t(i.a, 2000) }; });
    return o;
  }).filter(Boolean);
  const slug = String(p.slug ?? "").toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60);
  return { title: t(p.title, 120), slug, description: t(p.description, 300), sections: secs };
}

async function ask(b: Record<string, unknown>) {
  if (!KEY()) return { error: "The AI is not set up yet. Add ANTHROPIC_API_KEY in Supabase, Edge Functions, Secrets." };
  const imgs = (Array.isArray(b.images) ? b.images : []).map(String).filter((u) => u.startsWith(IMG)).slice(0, 8);
  const lib = (Array.isArray(b.library) ? b.library : []).slice(0, 80).map((x) => x as { src?: string; label?: string }).filter((x) => String(x.src ?? "").startsWith(IMG));
  const allowed = new Set<string>([...imgs, ...lib.map((x) => String(x.src))]);
  const content: unknown[] = imgs.map((u) => ({ type: "image", source: { type: "url", url: u } }));
  const parts: string[] = [];
  if (imgs.length) parts.push(`The photos above were attached by the gym for this page. Their URLs, in order:\n${imgs.join("\n")}\nUse them where they fit best (the strongest wide one for the hero).`);
  if (lib.length) parts.push(`Other photos you may use (URL, then what it shows):\n${lib.map((x) => `${x.src} | ${String(x.label ?? "").slice(0, 80)}`).join("\n")}`);
  if (b.mode === "edit") {
    const page = b.page as Record<string, unknown>;
    if (!page || !Array.isArray(page.sections)) return { error: "No page to change." };
    for (const s of page.sections as Record<string, unknown>[]) { if (s?.image) allowed.add(String(s.image)); for (const u of (Array.isArray(s?.images) ? s.images : [])) allowed.add(String(u)); for (const i of (Array.isArray(s?.items) ? s.items : [])) if ((i as Record<string, unknown>)?.image) allowed.add(String((i as Record<string, unknown>).image)); }
    parts.push(`Here is the current page:\n${JSON.stringify({ title: page.title, slug: page.slug, description: page.description, sections: page.sections })}`);
    parts.push(`Change it as the gym asks, and keep everything else the same (same wording, photos and order unless the request needs a change). The request:\n${String(b.ask ?? "").slice(0, 3000)}`);
  } else {
    const brief = String(b.brief ?? "").slice(0, 4000).trim();
    if (!brief) return { error: "Describe the page you want first." };
    parts.push(`Make a new page. What the gym wants:\n${brief}`);
  }
  parts.push("Reply with the whole page as JSON only.");
  content.push({ type: "text", text: parts.join("\n\n") });
  const slot = await admin.rpc("ai_usage_take", { p_fn: "pages" });
  if (slot.error) return { error: "Could not check the AI allowance. Try again." };
  if (!slot.data) return { error: "This month's AI allowance is used up. It starts again on the 1st of next month." };
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", headers: { "x-api-key": KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 12000, system: VOICE, messages: [{ role: "user", content }] }),
  });
  const j = await r.json().catch(() => ({}));
  await admin.from("ai_usage").update({ in_tokens: j?.usage?.input_tokens ?? null, out_tokens: j?.usage?.output_tokens ?? null, ok: r.ok }).eq("id", slot.data);
  if (!r.ok) return { error: "The AI said: " + (j?.error?.message ?? r.status) };
  const out = String((j.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join(""));
  try {
    const page = clean(JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1)), allowed);
    if (!page.sections.length) throw new Error("empty");
    return { page };
  } catch { return { error: "The AI answer could not be read. Try again, or describe it a little differently." }; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  try {
    if (!(await manager(req))) return json({ error: "Only a manager can do this." }, 401);
    const b = await req.json().catch(() => ({}));
    if (b.mode !== "make" && b.mode !== "edit") return json({ error: "Unknown request." }, 400);
    return json(await ask(b));
  } catch (e) { return json({ error: (e as Error).message }); }
});
