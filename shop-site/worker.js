/* A shop's own domain (for example karahill's): the website on the domain, the shop's app at /app/.
   The files are the ones app.phuketking.com already serves for the shop (massagemate/<shop>/), this Worker only fetches them.
   Which shop: SHOP_PATH in wrangler.jsonc. The domain is added in Cloudflare: this Worker, Settings, Domains and Routes, Custom domain.
   One Worker per shop domain: copy this folder's wrangler.jsonc with a new name and SHOP_PATH. */

const ORIGIN = "https://app.phuketking.com";

export default {
  async fetch(request, env) {
    const shop = "/" + String(env.SHOP_PATH || "").replace(/^\/+|\/+$/g, "");
    if (shop === "/") return new Response("Shop not set", { status: 500 });
    const url = new URL(request.url);
    // one address: www goes to the bare domain
    if (url.hostname.startsWith("www.")) return Response.redirect("https://" + url.hostname.slice(4) + url.pathname + url.search, 301);
    let p = url.pathname;
    if (p === "/app") return Response.redirect(url.origin + "/app/" + url.search, 301);
    // old links straight to the site folder
    if (p === "/site" || p.startsWith("/site/")) return Response.redirect(url.origin + "/" + url.search + url.hash, 301);

    let target;
    if (p === "/" || p === "/index.html") target = shop + "/site/index.html";
    else if (p.startsWith("/app/")) target = shop + p.slice(4);
    else target = shop + p;

    const res = await fetch(new Request(ORIGIN + target + url.search, {
      method: request.method, headers: request.headers,
      body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body, redirect: "manual",
    }));
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      if (loc) {
        const l = new URL(loc, ORIGIN + target);
        if (l.origin === ORIGIN && l.pathname.startsWith(shop + "/")) {
          let np = l.pathname.slice(shop.length);
          np = np.startsWith("/site/") ? "/" : "/app" + np;
          const h = new Headers(res.headers); h.set("location", url.origin + np + l.search + l.hash);
          return new Response(null, { status: res.status, headers: h });
        }
      }
      return res;
    }
    const r = new Response(res.body, res);
    r.headers.set("Strict-Transport-Security", "max-age=31536000");
    r.headers.set("X-Content-Type-Options", "nosniff");
    r.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
    return r;
  },
};
