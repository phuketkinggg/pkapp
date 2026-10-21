// Social media posts from the app: the AI writes the caption, a manager approves it, and it goes out on time.
// Facebook page and Instagram (business account linked to the page) through Meta's own API. No other service in between.
// POST {mode:'check'}  manager: is the AI key and the Meta page set up (page name, Instagram username)
// POST {mode:'write', brief, caption?, ask?, platforms?, images?}  manager: 3 caption options from Claude
// POST {mode:'run'}    the 5 minute timer (x-sync-token) or a manager (Post now): sends every post that is due
// Secrets: ANTHROPIC_API_KEY (AI captions), META_PAGE_TOKEN (a never-expiring Facebook page token)
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const AI_KEY = () => (Deno.env.get("ANTHROPIC_API_KEY") ?? "").trim();
const PAGE_TOKEN = () => (Deno.env.get("META_PAGE_TOKEN") ?? "").trim();
const MODEL = "claude-sonnet-5-5";
const G = "https://graph.facebook.com/v23.0";
const MEDIA = URL_ + "/storage/v1/object/public/social/";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-token", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// house style: never a long dash, never an ampersand
const tidy = (s: string) => String(s ?? "").replace(/\s*[\u2014\u2013]\s*/g, ", ").replace(/\s&\s/g, " and ").replace(/,\s*,/g, ",").trim();

const VOICE = `You write social media posts for Phuket King Muay Thai (PKMT), a Muay Thai gym in Kathu, Phuket, Thailand. Website phuketking.com, WhatsApp +66 969 076 150.
About the gym: known for technical coaching, from complete beginners to fighters. Tagline "Work hard, Fight easy". New lakeside site with a ring, heavy bags, a free weight zone, a recovery area (sauna, steam room, ice bath, yoga), Pangea Resort lakeside bungalows on site, and Pangea Cafe with healthy food. Guests come from all over the world; many stay for weeks or months, some on a DTV visa.
Voice: warm, confident, real, a bit of humour, never salesy or cheesy. Short lines that read well on a phone. Lead with a hook in the first line. Speak to people who are curious about training in Thailand as well as to members.
Hard rules:
- Never use a long dash (em dash or en dash). Use a comma, a full stop or a new line instead.
- Never use the & sign. Always write "and".
- Do not invent facts: no prices, dates, names, results, offers or numbers unless they are in the brief.
- Emojis: a few at most, only where they add something.
- End with a short call to action that fits (for example: message us on WhatsApp, link in bio, come and train with us).
- Instagram: put 5 to 10 relevant hashtags on their own line at the end (for example #muaythai #phuket #muaythaithailand #phuketkingmuaythai). Facebook only: 0 to 3 hashtags.
- Up to about 150 words unless the brief asks for more.`;

async function manager(req: Request) {
  const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
  const { data } = await user.auth.getUser();
  if (!data?.user) return false;
  const { data: s } = await admin.from("staff").select("role").eq("user_id", data.user.id).eq("active", true).maybeSingle();
  return s?.role === "manager";
}

// ---------- AI captions ----------
async function write(b: Record<string, unknown>) {
  if (!AI_KEY()) return { error: "The AI is not set up yet. Add ANTHROPIC_API_KEY in Supabase, Edge Functions, Secrets." };
  const brief = String(b.brief ?? "").slice(0, 2000).trim(), cur = String(b.caption ?? "").slice(0, 2200).trim(), ask = String(b.ask ?? "").slice(0, 500).trim();
  if (!brief && !cur) return { error: "Write a few words about the post first." };
  const pl = (Array.isArray(b.platforms) ? b.platforms : []).filter((x) => x === "facebook" || x === "instagram");
  const imgs = (Array.isArray(b.images) ? b.images : []).map(String).filter((u) => u.startsWith(MEDIA)).slice(0, 4);
  const text = [
    `Platforms: ${pl.length ? pl.join(" and ") : "Facebook and Instagram"} (one caption is used for all of them).`,
    imgs.length ? `The ${imgs.length > 1 ? "photos above are" : "photo above is"} what will be posted${b.has_video ? " (a frame from the video)" : ""}. Use what you see, but do not guess names or places you cannot know.` : "",
    brief ? `What the post is about, from the gym:\n${brief}` : "",
    cur ? `The current caption:\n${cur}` : "",
    ask ? `Change asked for: ${ask}` : cur ? "Improve the current caption, keep its meaning." : "",
    `Give 3 different options (for example: a story, a punchy short one, an informative one). Reply with JSON only, no other text: {"options":[{"style":"two or three words","caption":"..."}]}`,
  ].filter(Boolean).join("\n\n");
  const content: unknown[] = imgs.map((u) => ({ type: "image", source: { type: "url", url: u } }));
  content.push({ type: "text", text });
  const slot = await admin.rpc("ai_usage_take", { p_fn: "social" });
  if (slot.error) return { error: "Could not check the AI allowance. Try again." };
  if (!slot.data) return { error: "This month's AI allowance is used up. It starts again on the 1st of next month." };
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", headers: { "x-api-key": AI_KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 2000, system: VOICE, messages: [{ role: "user", content }] }),
  });
  const j = await r.json().catch(() => ({}));
  await admin.from("ai_usage").update({ in_tokens: j?.usage?.input_tokens ?? null, out_tokens: j?.usage?.output_tokens ?? null, ok: r.ok }).eq("id", slot.data);
  if (!r.ok) return { error: "The AI said: " + (j?.error?.message ?? r.status) };
  const out = String((j.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join(""));
  try {
    const o = JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1));
    const options = (o.options ?? []).map((x: { style?: string; caption?: string }) => ({ style: tidy(String(x.style ?? "")).slice(0, 40), caption: tidy(String(x.caption ?? "")).slice(0, 2200) })).filter((x: { caption: string }) => x.caption);
    if (!options.length) throw new Error("empty");
    return { options };
  } catch { return { options: [{ style: "Caption", caption: tidy(out).slice(0, 2200) }] }; }
}

// ---------- Meta ----------
// the secret can be a page token or a system user token; for a system user token the page's own token is fetched once
let pageTok = "";
async function graph(path: string, params: Record<string, string> = {}, method = "POST") {
  const q = new URLSearchParams({ ...params, access_token: pageTok || PAGE_TOKEN() });
  const r = await fetch(method === "GET" ? `${G}/${path}?${q}` : `${G}/${path}`, method === "GET" ? {} : { method, body: q });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(j?.error?.error_user_msg ?? j?.error?.message ?? `Meta said ${r.status}`);
  return j;
}
let acct: { page: string; name: string; ig: string | null; ig_name: string | null } | null = null;
async function account() {
  if (acct) return acct;
  pageTok = "";
  const me = await graph("me", { fields: "id,name" }, "GET");
  let j: { id: string; name: string; access_token?: string; instagram_business_account?: { id: string; username: string } };
  try { j = await graph(me.id, { fields: "id,name,instagram_business_account{id,username}" }, "GET"); }
  catch {
    // a system user token: use the first page it manages, with that page's own token
    const acc = await graph("me/accounts", { fields: "id,name,access_token,instagram_business_account{id,username}" }, "GET");
    j = (acc.data ?? [])[0];
    if (!j) throw new Error("The token cannot see any Facebook page. Assign the page to the system user.");
    pageTok = j.access_token ?? "";
  }
  acct = { page: j.id, name: j.name, ig: j.instagram_business_account?.id ?? null, ig_name: j.instagram_business_account?.username ?? null };
  return acct;
}

type Media = { url: string; type: "image" | "video" };
type Res = { id?: string; url?: string; error?: string; container?: string };
type Post = { id: string; caption: string; media: Media[]; platforms: string[]; results: Record<string, Res>; kind?: string; trial_strategy?: string | null };

async function toFacebook(p: Post, a: { page: string }): Promise<Res> {
  const m = p.media ?? [], cap = p.caption ?? "";
  let id: string;
  if (m[0]?.type === "video") {
    // a Reel on Facebook: start an upload, Facebook fetches the file from our storage, then publish
    try {
      const st = await graph(`${a.page}/video_reels`, { upload_phase: "start" });
      const up = await fetch(`https://rupload.facebook.com/video-upload/v23.0/${st.video_id}`, { method: "POST", headers: { Authorization: `OAuth ${pageTok || PAGE_TOKEN()}`, file_url: m[0].url } });
      const uj = await up.json().catch(() => ({}));
      if (!up.ok || uj.success === false) throw new Error(uj?.debug_info?.message ?? `upload ${up.status}`);
      await graph(`${a.page}/video_reels`, { upload_phase: "finish", video_id: st.video_id, video_state: "PUBLISHED", description: cap });
      return { id: st.video_id, url: `https://www.facebook.com/reel/${st.video_id}` };
    } catch {
      // not a shape Facebook takes as a Reel (for example landscape or over 90 seconds): post it as a normal video
      const j = await graph(`${a.page}/videos`, { file_url: m[0].url, description: cap });
      id = j.id; return { id, url: `https://www.facebook.com/${a.page}/videos/${id}` };
    }
  }
  if (m.length === 1) { const j = await graph(`${a.page}/photos`, { url: m[0].url, message: cap }); id = j.post_id ?? j.id; }
  else if (m.length > 1) {
    const ids: string[] = [];
    for (const x of m) ids.push((await graph(`${a.page}/photos`, { url: x.url, published: "false" })).id);
    const prm: Record<string, string> = { message: cap };
    ids.forEach((x, i) => prm[`attached_media[${i}]`] = JSON.stringify({ media_fbid: x }));
    id = (await graph(`${a.page}/feed`, prm)).id;
  } else id = (await graph(`${a.page}/feed`, { message: cap })).id;
  return { id, url: `https://www.facebook.com/${id}` };
}

// Instagram makes a "container" first; videos need time to process, so the container is kept and checked again on the next run
async function toInstagram(p: Post, a: { ig: string | null }, prev: Res | undefined): Promise<Res> {
  if (!a.ig) return { error: "No Instagram business account is linked to the Facebook page." };
  const m = p.media ?? [], cap = p.caption ?? "";
  if (!m.length) return { error: "Instagram needs a photo or video." };
  let container = prev?.container;
  if (!container) {
    if (m[0].type === "video") {
      const prm: Record<string, string> = { media_type: "REELS", video_url: m[0].url, caption: cap };
      // a Trial Reel is shown to people who do not follow you first; MANUAL: you share it to followers in the Instagram app, SS_PERFORMANCE: Instagram does it if it does well
      if (p.kind === "trial") prm.trial_params = JSON.stringify({ graduation_strategy: p.trial_strategy === "SS_PERFORMANCE" ? "SS_PERFORMANCE" : "MANUAL" });
      else prm.share_to_feed = "true";
      container = (await graph(`${a.ig}/media`, prm)).id;
    }
    else if (m.length === 1) container = (await graph(`${a.ig}/media`, { image_url: m[0].url, caption: cap })).id;
    else {
      const kids: string[] = [];
      for (const x of m) kids.push((await graph(`${a.ig}/media`, { image_url: x.url, is_carousel_item: "true" })).id);
      container = (await graph(`${a.ig}/media`, { media_type: "CAROUSEL", children: kids.join(","), caption: cap })).id;
    }
  }
  for (let i = 0; i < 10; i++) {
    const s = await graph(container!, { fields: "status_code" }, "GET");
    if (s.status_code === "FINISHED") break;
    if (s.status_code === "ERROR" || s.status_code === "EXPIRED") return { error: "Instagram could not process this file. Videos should be MP4, 3 to 90 seconds, upright 9:16 works best." };
    if (i === 9) return { container }; // still processing: finish on the next run
    await sleep(5000);
  }
  const pub = await graph(`${a.ig}/media_publish`, { creation_id: container! });
  let url: string | undefined;
  try { url = (await graph(pub.id, { fields: "permalink" }, "GET")).permalink; } catch { /* link is a nice-to-have */ }
  return { id: pub.id, url, container };
}

async function run() {
  const { data, error } = await admin.rpc("social_take");
  if (error) return { error: error.message };
  const posts = (data ?? []) as Post[];
  if (!posts.length) return { ok: true, posts: 0 };
  let a: Awaited<ReturnType<typeof account>> | null = null, aErr = "";
  if (!PAGE_TOKEN()) aErr = "Facebook and Instagram are not connected yet. Add META_PAGE_TOKEN in Supabase.";
  else { try { a = await account(); } catch (e) { aErr = "Meta did not accept the page token: " + (e as Error).message; } }
  const done: string[] = [];
  for (const p of posts) {
    const results: Record<string, Res> = { ...(p.results ?? {}) };
    for (const pl of p.platforms) {
      if (results[pl]?.id) continue;
      if (!a) { results[pl] = { error: aErr }; continue; }
      try { results[pl] = pl === "facebook" ? await toFacebook(p, a) : await toInstagram(p, a, results[pl]); }
      catch (e) { results[pl] = { ...(results[pl]?.container ? { container: results[pl].container } : {}), error: (e as Error).message }; }
    }
    const vals = p.platforms.map((pl) => results[pl] ?? {});
    const waiting = vals.some((v) => !v.id && !v.error);
    const failed = vals.filter((v) => v.error);
    const status = waiting ? "posting" : failed.length ? "failed" : "posted";
    await admin.rpc("social_done", { p_id: p.id, p_results: results, p_status: status, p_error: failed.length ? failed.map((v) => v.error).join(" ") : null });
    done.push(p.id + ":" + status);
  }
  return { ok: true, posts: posts.length, done };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  try {
    if (b.mode === "run") {
      const tok = req.headers.get("x-sync-token");
      let ok = false;
      if (tok) { const { data } = await admin.rpc("sync_token_ok", { p_token: tok }); ok = data === true; }
      if (!ok) ok = await manager(req);
      if (!ok) return json({ error: "Not allowed." }, 401);
      return json(await run());
    }
    if (!(await manager(req))) return json({ error: "Only a manager can do this." }, 401);
    if (b.mode === "write") return json(await write(b));
    if (b.mode === "check") {
      const out: Record<string, unknown> = { ai: !!AI_KEY(), meta: false };
      if (PAGE_TOKEN()) {
        try { const a = await account(); out.meta = true; out.page = a.name; out.instagram = a.ig_name; }
        catch (e) { out.meta_error = (e as Error).message; }
      }
      return json(out);
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
