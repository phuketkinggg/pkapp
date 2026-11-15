/* Each Muay Friend gym on its own address.
     <name>.muayfriend.com          the gym's app (members, coaches, back office)
     <name>.muayfriend.com/site/    the gym's website
   The files are the same ones muayfriend.com serves (/app/ and /site/); this Worker only fetches them and tells
   the page which gym it is (window.MF_HOST_GYM), so a link can never open another gym on this address.
   Which gym a name belongs to: public.mf_gym_by_sub in the Muay Friend free database (mf.gyms.sub), cached 5 minutes.
   Deployed from GitHub (Cloudflare Workers Builds, root directory muayfriend-gyms). Route: *.muayfriend.com/* */

let ORIGIN = "https://muayfriend.com";
let SB_URL = "https://bnglnfdgptvnmugntiom.supabase.co";
const SB_KEY = "sb_publishable_I2cEA2hEPelGTNMwf2zWwA_98_mxHT1"; // the public key the app itself uses
const TTL = 300, MISS_TTL = 60;
const NAME_OK = /^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/;
// same list as mf.sub_reserved in the database
const RESERVED = new Set(["app","apps","api","dash","admin","demo","site","sites","help","support","mail","email","smtp","status",
  "blog","docs","static","cdn","assets","muayfriend","muay","friend","login","signin","signup","account","billing","pay","stripe","test","dev","staging"]);
const SLUG_OK = /^[a-z][a-z0-9_]{1,40}$/;
// Muay Friend's own pages: on a gym address these go back to muayfriend.com
const OURS = /^\/(dash|demo|help|support|resources|leak|th|launch\.js|stats\.js|gyms\.json|sitemap\.xml)(\/|$)/;
// shared files that live at the top of muayfriend.com, not in /app/
const SHARED = /^\/(favicon\.svg|logo\.svg|logo-mark\.svg|fonts\/)/;

export default {
  async fetch(request, env, ctx) {
    if (env && env.TEST_ORIGIN) { ORIGIN = env.TEST_ORIGIN; SB_URL = env.TEST_SB; } // local tests only
    const url = new URL(request.url);
    const host = url.hostname.toLowerCase();
    if (!host.endsWith(".muayfriend.com")) return fetch(request);
    const name = host.slice(0, -".muayfriend.com".length);
    if (name === "www") return Response.redirect(ORIGIN + url.pathname + url.search, 301);
    // our own addresses (and any we add later) are never gyms: leave them alone
    if (RESERVED.has(name)) return fetch(request);
    if (!NAME_OK.test(name) || name.includes("--")) return Response.redirect(ORIGIN + "/", 302);

    const gym = await lookup(name, ctx);
    if (!gym) return Response.redirect(ORIGIN + "/?nogym=" + encodeURIComponent(name), 302);

    let path = url.pathname;
    if (OURS.test(path)) return Response.redirect(ORIGIN + path + url.search, 302);
    // old style links on the gym's own address: /app/?g=x -> /
    if (path === "/app" || path.startsWith("/app/")) {
      const q = new URLSearchParams(url.search); q.delete("g");
      const s = q.toString();
      return Response.redirect(url.origin + (path.slice(4) || "/") + (s ? "?" + s : "") + url.hash, 301);
    }
    if (path === "/site") return Response.redirect(url.origin + "/site/" + url.search, 301);

    let target;
    if (path.startsWith("/site/") || SHARED.test(path)) target = ORIGIN + path;
    else target = ORIGIN + "/app" + path;
    target += url.search;

    const res = await fetch(new Request(target, {
      method: request.method,
      headers: request.headers,
      body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
      redirect: "manual",
    }));

    // a redirect from muayfriend.com back into /app/ or /site/: keep it on the gym's address
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      if (loc) {
        const l = new URL(loc, target);
        if (l.hostname === "muayfriend.com" && (l.pathname.startsWith("/app/") || l.pathname.startsWith("/site/"))) {
          const p = l.pathname.startsWith("/app/") ? l.pathname.slice(4) : l.pathname;
          const h = new Headers(res.headers); h.set("location", url.origin + p + l.search + l.hash);
          return new Response(null, { status: res.status, headers: h });
        }
      }
      return res;
    }

    const type = res.headers.get("content-type") || "";
    if (path.endsWith("manifest.webmanifest") && res.ok) return manifest(res, gym);
    if (!type.includes("text/html") || !res.ok) return withHeaders(res);

    const tag = "<script>window.MF_HOST_GYM=" + JSON.stringify(gym.slug) + ";</script>";
    const nm = gym.name || "";
    let rw = new HTMLRewriter().on("head", { element(e) { e.prepend(tag, { html: true }); } });
    if (nm && !path.startsWith("/site/")) {
      rw = rw
        .on("title", { element(e) { e.setInnerContent(nm); } })
        .on('meta[name="apple-mobile-web-app-title"]', { element(e) { e.setAttribute("content", nm); } });
    }
    if (gym.bg) rw = rw.on('meta[name="theme-color"]', { element(e) { e.setAttribute("content", gym.bg); } });
    return withHeaders(rw.transform(res), true);
  },
};

async function lookup(name, ctx) {
  const cache = caches.default;
  const key = new Request("https://mf-gym-cache.invalid/" + name);
  const hit = await cache.match(key);
  if (hit) { const j = await hit.json(); return j && j.slug ? j : null; }
  let gym = null;
  try {
    const r = await fetch(SB_URL + "/rest/v1/rpc/mf_gym_by_sub", {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: SB_KEY, Authorization: "Bearer " + SB_KEY },
      body: JSON.stringify({ p_sub: name }),
    });
    if (!r.ok) return null; // database not answering: do not cache, try again next time
    const j = await r.json();
    if (j && SLUG_OK.test(j.slug || "")) gym = { slug: j.slug, name: String(j.name || "").slice(0, 80), bg: okColour(j.bg), accent: okColour(j.accent) };
  } catch (e) { return null; }
  ctx.waitUntil(cache.put(key, new Response(JSON.stringify(gym || {}), {
    headers: { "Content-Type": "application/json", "Cache-Control": "max-age=" + (gym ? TTL : MISS_TTL) },
  })));
  return gym;
}

// a home screen label fits about 12 to 14 letters: as many whole words as fit ("Core Combat Sports" -> "Core Combat")
function shortName(n) {
  if (n.length <= 14) return n;
  let out = "";
  for (const w of n.split(/\s+/)) { const t = out ? out + " " + w : w; if (t.length > 14) break; out = t; }
  return out || n.slice(0, 14);
}

function okColour(c) { return /^#[0-9a-fA-F]{3,8}$/.test(c || "") ? c : null; }

// the home screen icon says the gym's name, in the gym's colours
async function manifest(res, gym) {
  let m;
  try { m = await res.json(); } catch (e) { return res; }
  if (gym.name) { m.name = gym.name; m.short_name = shortName(gym.name); }
  m.description = "The " + (gym.name || "gym") + " app.";
  m.id = "/"; m.start_url = "/"; m.scope = "/";
  if (gym.bg) { m.background_color = gym.bg; m.theme_color = gym.bg; }
  return new Response(JSON.stringify(m), { headers: { "Content-Type": "application/manifest+json", "Cache-Control": "max-age=300" } });
}

function withHeaders(res, html) {
  const r = new Response(res.body, res);
  r.headers.set("Strict-Transport-Security", "max-age=31536000");
  r.headers.set("X-Content-Type-Options", "nosniff");
  r.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  if (html) { r.headers.set("X-Frame-Options", "DENY"); r.headers.set("Cache-Control", "no-cache"); r.headers.delete("content-length"); }
  return r;
}
