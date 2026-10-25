// Social media posts from the app: the AI writes the caption, a manager approves it, and it goes out on time.
// Facebook page and Instagram (business account linked to the page) through Meta's own API. No other service in between.
// POST {mode:'check'}  manager: is the AI key and the Meta page set up (page name, Instagram username)
// POST {mode:'write', brief, caption?, ask?, platforms?, images?}  manager: 3 caption options from Claude
// POST {mode:'cover', frames, brief?, caption?}  manager: 3 cover ideas for a reel (best frame and a short headline); the app draws the cover
// Kinds: post, reel, trial (Instagram trial reel), story (one photo or video, 24 hours, Instagram and Facebook)
// POST {mode:'run'}    the 5 minute timer (x-sync-token) or a manager (Post now): sends every post that is due
// POST {mode:'stats', n?}  timer token or manager: views, reach, likes, saves and shares of the last Instagram posts, marked if sent from the app
// POST {mode:'yt_connect'} manager: the Google sign in link to connect a YouTube channel; Google comes back here (GET ?code&state)
// Secrets: ANTHROPIC_API_KEY (AI captions), META_PAGE_TOKEN (a never-expiring Facebook page token),
//          GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET (YouTube; the redirect address is this function's own URL)
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

// ---------- AI covers for reels: picks the best frames and writes a short headline; the app draws the cover ----------
async function cover(b: Record<string, unknown>) {
  if (!AI_KEY()) return { error: "The AI is not set up yet. Add ANTHROPIC_API_KEY in Supabase, Edge Functions, Secrets." };
  const frames = (Array.isArray(b.frames) ? b.frames : []).map(String).filter((u) => u.startsWith(MEDIA)).slice(0, 8);
  if (frames.length < 2) return { error: "Could not read frames from the video. Try again." };
  const brief = String(b.brief ?? "").slice(0, 1500).trim(), cap = String(b.caption ?? "").slice(0, 1500).trim();
  const content: unknown[] = [];
  frames.forEach((u, i) => { content.push({ type: "text", text: `Frame ${i + 1}:` }); content.push({ type: "image", source: { type: "url", url: u } }); });
  content.push({ type: "text", text: [
    "These are frames from a short upright video (a Reel). Make 3 different cover ideas.",
    brief ? `What the video is about: ${brief}` : "", cap ? `The caption: ${cap}` : "",
    "For each: pick the frame that makes the strongest cover (sharp, a clear face or a strong action moment, not blurry, not a black or title frame), and write a headline of 2 to 5 words that makes people stop scrolling. A short second line of up to 6 words is optional.",
    "Headlines in plain words, no hashtags, no emojis, no long dashes, no & sign. Do not invent names, prices or facts.",
    'Reply with JSON only: {"covers":[{"frame":1,"headline":"...","sub":"..."}]}',
  ].filter(Boolean).join("\n\n") });
  const slot = await admin.rpc("ai_usage_take", { p_fn: "cover" });
  if (slot.error) return { error: "Could not check the AI allowance. Try again." };
  if (!slot.data) return { error: "This month's AI allowance is used up. It starts again on the 1st of next month." };
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", headers: { "x-api-key": AI_KEY(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 800, system: VOICE, messages: [{ role: "user", content }] }),
  });
  const j = await r.json().catch(() => ({}));
  await admin.from("ai_usage").update({ in_tokens: j?.usage?.input_tokens ?? null, out_tokens: j?.usage?.output_tokens ?? null, ok: r.ok }).eq("id", slot.data);
  if (!r.ok) return { error: "The AI said: " + (j?.error?.message ?? r.status) };
  const out = String((j.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join(""));
  try {
    const o = JSON.parse(out.slice(out.indexOf("{"), out.lastIndexOf("}") + 1));
    const covers = (o.covers ?? []).map((x: { frame?: number; headline?: string; sub?: string }) => ({
      frame: Math.min(frames.length, Math.max(1, Number(x.frame) || 1)) - 1, headline: tidy(String(x.headline ?? "")).slice(0, 60), sub: tidy(String(x.sub ?? "")).slice(0, 60) })).filter((x: { headline: string }) => x.headline).slice(0, 3);
    if (!covers.length) throw new Error("empty");
    return { covers };
  } catch { return { error: "The AI did not give covers this time. Try again." }; }
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
// place: the page itself, when it has an address, so posts can be tagged at the business location
let acct: { page: string; name: string; ig: string | null; ig_name: string | null; place: string | null; place_name: string | null } | null = null;
async function account() {
  if (acct) return acct;
  pageTok = "";
  const me = await graph("me", { fields: "id,name" }, "GET");
  let j: { id: string; name: string; access_token?: string; location?: { city?: string; street?: string }; instagram_business_account?: { id: string; username: string } };
  try { j = await graph(me.id, { fields: "id,name,instagram_business_account{id,username}" }, "GET"); }
  catch {
    // a system user token: use the first page it manages, with that page's own token
    const acc = await graph("me/accounts", { fields: "id,name,access_token,instagram_business_account{id,username}" }, "GET");
    j = (acc.data ?? [])[0];
    if (!j) throw new Error("The token cannot see any Facebook page. Assign the page to the system user.");
    pageTok = j.access_token ?? "";
  }
  // the address on the page (best effort: no address, no location tag)
  try { j.location = (await graph(j.id, { fields: "location" }, "GET")).location; } catch { /* no location */ }
  acct = { page: j.id, name: j.name, ig: j.instagram_business_account?.id ?? null, ig_name: j.instagram_business_account?.username ?? null,
    place: j.location ? j.id : null, place_name: j.location ? [j.name, j.location.city].filter(Boolean).join(", ") : null };
  return acct;
}

type Media = { url: string; type: "image" | "video"; cover?: string };
type Res = { id?: string; url?: string; error?: string; container?: string };
type Post = { id: string; caption: string; media: Media[]; platforms: string[]; results: Record<string, Res>; kind?: string; trial_strategy?: string | null; tag_place?: boolean; collaborators?: string[] };

// the cover the gym chose: uploaded as the video's thumbnail (best effort, the video is already up)
async function fbCover(videoId: string, cover: string) {
  try {
    const img = await fetch(cover); if (!img.ok) return;
    const fd = new FormData(); fd.append("source", new Blob([await img.arrayBuffer()], { type: "image/jpeg" }), "cover.jpg"); fd.append("is_preferred", "true"); fd.append("access_token", pageTok || PAGE_TOKEN());
    await fetch(`${G}/${videoId}/thumbnails`, { method: "POST", body: fd });
  } catch { /* the reel stays up with Facebook's own thumbnail */ }
}
// a Facebook page story: one photo (uploaded hidden, then shared as a story) or one video (upload, then finish)
async function fbStory(p: Post, a: { page: string }): Promise<Res> {
  const m = (p.media ?? [])[0];
  if (!m) return { error: "A story needs a photo or a video." };
  if (m.type === "video") {
    const st = await graph(`${a.page}/video_stories`, { upload_phase: "start" });
    const up = await fetch(`https://rupload.facebook.com/video-upload/v23.0/${st.video_id}`, { method: "POST", headers: { Authorization: `OAuth ${pageTok || PAGE_TOKEN()}`, file_url: m.url } });
    const uj = await up.json().catch(() => ({}));
    if (!up.ok || uj.success === false) throw new Error(uj?.debug_info?.message ?? `Facebook story upload ${up.status}`);
    const fin = await graph(`${a.page}/video_stories`, { upload_phase: "finish", video_id: st.video_id });
    return { id: fin.post_id ?? st.video_id, url: `https://www.facebook.com/${a.page}` };
  }
  const ph = await graph(`${a.page}/photos`, { url: m.url, published: "false" });
  const st = await graph(`${a.page}/photo_stories`, { photo_id: ph.id });
  return { id: st.post_id ?? ph.id, url: `https://www.facebook.com/${a.page}` };
}
async function toFacebook(p: Post, a: { page: string }): Promise<Res> {
  if (p.kind === "story") return await fbStory(p, a);
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
      if (m[0].cover?.startsWith(MEDIA)) await fbCover(st.video_id, m[0].cover);
      return { id: st.video_id, url: `https://www.facebook.com/reel/${st.video_id}` };
    } catch {
      // not a shape Facebook takes as a Reel (for example landscape or over 90 seconds): post it as a normal video
      const j = await graph(`${a.page}/videos`, { file_url: m[0].url, description: cap });
      id = j.id; if (m[0].cover?.startsWith(MEDIA)) await fbCover(id, m[0].cover); return { id, url: `https://www.facebook.com/${a.page}/videos/${id}` };
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
// a container with the location tag and collaborators; if Instagram refuses one of them, the post still goes out without it
async function igMake(a: { ig: string | null; place: string | null }, p: Post, prm: Record<string, string>) {
  const tags: Record<string, string> = {};
  if (p.tag_place !== false && a.place) tags.location_id = a.place;
  if ((p.collaborators ?? []).length && p.kind !== "trial") tags.collaborators = JSON.stringify((p.collaborators ?? []).slice(0, 3));
  const tries = [tags, tags.location_id ? { location_id: tags.location_id } : null, {}].filter((t) => t) as Record<string, string>[];
  let err: unknown = null;
  for (const t of tries) { try { return (await graph(`${a.ig}/media`, { ...prm, ...t })).id as string; } catch (e) { err = e; if (!Object.keys(t).length) break; } }
  throw err;
}
async function toInstagram(p: Post, a: { ig: string | null; place: string | null }, prev: Res | undefined): Promise<Res> {
  if (!a.ig) return { error: "No Instagram business account is linked to the Facebook page." };
  const m = p.media ?? [], cap = p.caption ?? "";
  if (!m.length) return { error: "Instagram needs a photo or video." };
  let container = prev?.container;
  // a story: one photo or one video, no caption (Instagram does not take one for stories)
  if (!container && p.kind === "story") container = (await graph(`${a.ig}/media`, m[0].type === "video" ? { media_type: "STORIES", video_url: m[0].url } : { media_type: "STORIES", image_url: m[0].url })).id;
  if (!container) {
    if (m[0].type === "video") {
      const prm: Record<string, string> = { media_type: "REELS", video_url: m[0].url, caption: cap };
      if (m[0].cover?.startsWith(MEDIA)) prm.cover_url = m[0].cover;
      // a Trial Reel is shown to people who do not follow you first; MANUAL: you share it to followers in the Instagram app, SS_PERFORMANCE: Instagram does it if it does well
      if (p.kind === "trial") prm.trial_params = JSON.stringify({ graduation_strategy: p.trial_strategy === "SS_PERFORMANCE" ? "SS_PERFORMANCE" : "MANUAL" });
      else prm.share_to_feed = "true";
      container = await igMake(a, p, prm);
    }
    else if (m.length === 1) container = await igMake(a, p, { image_url: m[0].url, caption: cap });
    else {
      const kids: string[] = [];
      for (const x of m) kids.push((await graph(`${a.ig}/media`, { image_url: x.url, is_carousel_item: "true" })).id);
      container = await igMake(a, p, { media_type: "CAROUSEL", children: kids.join(","), caption: cap });
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

// ---------- YouTube Shorts ----------
const SELF = URL_ + "/functions/v1/social";
const GID = () => (Deno.env.get("GOOGLE_CLIENT_ID") ?? "").trim();
const GSECRET = () => (Deno.env.get("GOOGLE_CLIENT_SECRET") ?? "").trim();
async function ytAccess(): Promise<string> {
  const { data } = await admin.rpc("yt_get");
  const refresh = (data as { refresh?: string } | null)?.refresh;
  if (!refresh) throw new Error("YouTube is not connected. Tap Connect YouTube in Social media.");
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", body: new URLSearchParams({ client_id: GID(), client_secret: GSECRET(), refresh_token: refresh, grant_type: "refresh_token" }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error("Google did not accept the YouTube link (" + (j.error_description ?? j.error ?? r.status) + "). Connect YouTube again.");
  return j.access_token;
}
async function toYouTube(p: Post): Promise<Res> {
  const m = p.media ?? [];
  if (m[0]?.type !== "video") return { error: "YouTube Shorts needs a video." };
  const tok = await ytAccess(), cap = p.caption ?? "";
  // the title: the first line of the caption, without hashtags, plus #Shorts
  let title = cap.split("\n").map((l) => l.replace(/#\S+/g, "").trim()).find((l) => l) ?? "New video";
  if (title.length > 88) title = title.slice(0, 85).replace(/\s+\S*$/, "") + "...";
  title = title.replace(/[<>]/g, "") + " #Shorts";
  const vid = await fetch(m[0].url);
  if (!vid.ok || !vid.body) return { error: "Could not read the video from storage." };
  const size = vid.headers.get("content-length") ?? "";
  const start = await fetch("https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status", {
    method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": vid.headers.get("content-type") ?? "video/mp4", ...(size ? { "X-Upload-Content-Length": size } : {}) },
    body: JSON.stringify({ snippet: { title, description: cap.replace(/[<>]/g, "").slice(0, 4900), categoryId: "17" }, status: { privacyStatus: "public", selfDeclaredMadeForKids: false } }),
  });
  const loc = start.headers.get("location");
  if (!start.ok || !loc) { const e = await start.json().catch(() => ({})); return { error: "YouTube said: " + (e?.error?.message ?? start.status) }; }
  const up = await fetch(loc, { method: "PUT", headers: { "Content-Type": vid.headers.get("content-type") ?? "video/mp4", ...(size ? { "Content-Length": size } : {}) }, body: vid.body, // @ts-ignore stream upload
    duplex: "half" });
  const uj = await up.json().catch(() => ({}));
  if (!up.ok || !uj.id) return { error: "YouTube upload did not finish: " + (uj?.error?.message ?? up.status) };
  // the cover, when the channel may set custom thumbnails (a verified channel); best effort
  if (m[0].cover?.startsWith(MEDIA)) {
    try { const img = await fetch(m[0].cover); if (img.ok) await fetch(`https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=${uj.id}`, { method: "POST", headers: { Authorization: `Bearer ${tok}`, "Content-Type": "image/jpeg" }, body: await img.arrayBuffer() }); }
    catch { /* YouTube keeps its own thumbnail */ }
  }
  return { id: uj.id, url: `https://www.youtube.com/shorts/${uj.id}` };
}
const page = (t: string, ok: boolean) => new Response(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YouTube</title><body style="font-family:system-ui,sans-serif;padding:32px;max-width:520px;margin:auto"><h2>${ok ? "YouTube connected" : "YouTube not connected"}</h2><p>${t.replace(/[<>&]/g, "")}</p><p>You can close this tab and go back to the app.</p></body>`, { headers: { "Content-Type": "text/html; charset=utf-8" } });
// the app page to go back to after Google (sent by the app when it starts the sign in); only a plain https page address
function backUrl(x: unknown): string {
  try { const u = new URL(String(x ?? "")); if (u.protocol !== "https:" && u.hostname !== "localhost") return ""; return u.origin + u.pathname; } catch { return ""; }
}
const b64e = (s: string) => btoa(unescape(encodeURIComponent(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64d = (s: string) => { try { return decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/")))); } catch { return ""; } };
async function ytCallback(u: URL) {
  const raw = u.searchParams.get("state") ?? "", cut = raw.indexOf("~");
  const state = cut >= 0 ? raw.slice(0, cut) : raw, back = cut >= 0 ? backUrl(b64d(raw.slice(cut + 1))) : "";
  // straight back to the app with the result (Supabase shows pages from functions as plain text, so the app shows the message)
  const done = (msg: string, ok: boolean) => back
    ? new Response(null, { status: 302, headers: { Location: back + "#yt=" + (ok ? "ok" : "err") + "&m=" + encodeURIComponent(msg) } })
    : page(msg, ok);
  if (u.searchParams.get("error")) return done("Google said: " + u.searchParams.get("error"), false);
  const code = u.searchParams.get("code") ?? "";
  const { data: ok } = await admin.rpc("yt_state_ok", { p_s: state });
  if (ok !== true) return done("The link was too old or was used already. Tap Connect YouTube again.", false);
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", body: new URLSearchParams({ code, client_id: GID(), client_secret: GSECRET(), redirect_uri: SELF, grant_type: "authorization_code" }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.refresh_token) return done("Google did not give access (" + (j.error_description ?? j.error ?? "no refresh token") + "). Try again, and allow every permission asked.", false);
  let channel = "";
  try { const c = await fetch("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", { headers: { Authorization: `Bearer ${j.access_token}` } }); const cj = await c.json(); channel = cj?.items?.[0]?.snippet?.title ?? ""; } catch { /* name is a nice-to-have */ }
  await admin.rpc("yt_set", { p: { refresh: j.refresh_token, channel, at: new Date().toISOString() } });
  return done(channel ? `YouTube connected. Shorts will post to the channel "${channel}".` : "YouTube connected. Shorts will post to your channel.", true);
}

async function stats(n: number) {
  if (!PAGE_TOKEN()) return { error: "Facebook and Instagram are not connected yet." };
  const a = await account();
  if (!a.ig) return { error: "No Instagram business account is linked to the Facebook page." };
  const { data: mine } = await admin.from("social_posts").select("results").eq("status", "posted");
  const fromApp = new Set((mine ?? []).map((r: { results: Record<string, Res> }) => r.results?.instagram?.id).filter(Boolean));
  const list = await graph(`${a.ig}/media`, { fields: "id,timestamp,media_type,media_product_type,permalink,like_count,comments_count,caption", limit: String(n) }, "GET");
  const out = [];
  for (const m of (list.data ?? []) as Record<string, unknown>[]) {
    const ins: Record<string, number> = {};
    for (const metric of ["views", "reach", "saved", "shares"]) {
      try { const r = await graph(`${m.id}/insights`, { metric }, "GET"); ins[metric] = r?.data?.[0]?.values?.[0]?.value ?? null; } catch { /* not every type has every number */ }
    }
    out.push({ id: m.id, at: m.timestamp, type: m.media_product_type ?? m.media_type, media: m.media_type, url: m.permalink, likes: m.like_count, comments: m.comments_count,
      from_app: fromApp.has(String(m.id)), caption: String(m.caption ?? "").split("\n")[0].slice(0, 80), ...ins });
  }
  return { account: a.ig_name, posts: out };
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
      if (!a && pl !== "youtube") { results[pl] = { error: aErr }; continue; }
      try { results[pl] = pl === "facebook" ? await toFacebook(p, a!) : pl === "youtube" ? await toYouTube(p) : await toInstagram(p, a!, results[pl]); }
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
  if (req.method === "GET") { const u = new URL(req.url); if (u.searchParams.has("state")) return await ytCallback(u); }
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const b = await req.json().catch(() => ({}));
  try {
    // numbers for the last Instagram posts (from the app or not): views, reach, likes, comments, saves, shares
    if (b.mode === "stats") {
      const tok = req.headers.get("x-sync-token");
      let ok = false;
      if (tok) { const { data } = await admin.rpc("sync_token_ok", { p_token: tok }); ok = data === true; }
      if (!ok) ok = await manager(req);
      if (!ok) return json({ error: "Not allowed." }, 401);
      return json(await stats(Math.min(50, Math.max(1, Number(b.n) || 25))));
    }
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
    if (b.mode === "cover") return json(await cover(b));
    if (b.mode === "yt_connect") {
      if (!GID() || !GSECRET()) return json({ error: "YouTube is not set up yet: GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are missing in Supabase, Edge Functions, Secrets." });
      const user = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }, auth: { persistSession: false } });
      const { data: st, error } = await user.rpc("yt_state_new");
      if (error || !st) return json({ error: error?.message ?? "Could not start." });
      const q = new URLSearchParams({ client_id: GID(), redirect_uri: SELF, response_type: "code", access_type: "offline", prompt: "consent", include_granted_scopes: "true", state: String(st) + (backUrl(b.back) ? "~" + b64e(backUrl(b.back)) : ""),
        scope: "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly" });
      return json({ url: "https://accounts.google.com/o/oauth2/v2/auth?" + q });
    }
    if (b.mode === "check") {
      const yt = ((await admin.rpc("yt_get")).data ?? {}) as { refresh?: string; channel?: string };
      const out: Record<string, unknown> = { ai: !!AI_KEY(), meta: false, youtube_ready: !!(GID() && GSECRET()), youtube: yt.refresh ? (yt.channel || "connected") : null };
      if (PAGE_TOKEN()) {
        try { const a = await account(); out.meta = true; out.page = a.name; out.instagram = a.ig_name; out.place = a.place_name; }
        catch (e) { out.meta_error = (e as Error).message; }
      }
      return json(out);
    }
    return json({ error: "Unknown request." }, 400);
  } catch (e) {
    return json({ error: (e as Error).message });
  }
});
