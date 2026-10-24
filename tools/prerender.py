#!/usr/bin/env python3
"""Pre-renders the parts of the website that are normally drawn by JavaScript, so Google and AI tools
(ChatGPT, Claude, Perplexity), which often read pages without running JavaScript, see the real text.

It opens the built website (site/) in a headless browser, lets the normal page code load the live content
(blog posts, pages made in the app, prices), and saves the drawn HTML to prerender/snapshot.json.
tools/build_site.py then writes each blog post and app page as its own page (www.phuketking.com/<slug>)
and puts the prices into prices.html. Visitors see the same page as before; the page code still loads
fresh content on top.

Run:  python3 tools/build_site.py && python3 tools/prerender.py && python3 tools/build_site.py
(a GitHub Action does this every few hours, see .github/workflows/prerender.yml)
"""
import functools, http.server, json, os, sys, threading, urllib.request, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT = os.path.join(ROOT, "prerender", "snapshot.json")
REST = "https://jijnshwduhgegacfvpkh.supabase.co/rest/v1/"
FN = "https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/site"
KEY = "sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i"
SLUG_OK = __import__("re").compile(r"^[a-z0-9-]{1,121}$")


def get(url):
    req = urllib.request.Request(url, headers={"apikey": KEY, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    posts = get(REST + "blog_posts?select=slug,title,excerpt,cover_url,published_at&status=eq.published&order=published_at.desc")
    pages = get(REST + "site_pages?select=slug,title,description,updated_at&status=eq.published&removed=eq.false&order=slug")
    data = get(FN)
    posts = [p for p in posts if SLUG_OK.match(p.get("slug") or "")]
    pages = [p for p in pages if SLUG_OK.match(p.get("slug") or "")]

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=SITE))
    srv.RequestHandlerClass.log_message = lambda *a: None
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d/" % srv.server_address[1]

    from playwright.sync_api import sync_playwright
    snap = {"posts": [], "pages": [], "prices": None}
    errors = []
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(bypass_csp=True)
        # no pictures or fonts needed to read the text; no visit counting
        ctx.route("**/*", lambda r: r.abort() if r.request.resource_type in ("image", "font", "media") or "site_track" in r.request.url else r.continue_())
        pg = ctx.new_page()

        for post in posts:
            try:
                pg.goto(base + "post.html?p=" + post["slug"] + "&notrack=1", wait_until="domcontentloaded")
                pg.wait_for_selector("#post h1", timeout=25000)
                html = pg.eval_on_selector("#post", "e => e.innerHTML")
                snap["posts"].append({"slug": post["slug"], "title": post["title"], "description": post.get("excerpt") or "",
                                      "image": post.get("cover_url") or "", "published": post.get("published_at"), "html": html})
            except Exception as e:
                errors.append("post %s: %s" % (post["slug"], e))

        for page in pages:
            try:
                pg.goto(base + "page.html?p=" + page["slug"] + "&notrack=1", wait_until="domcontentloaded")
                pg.wait_for_function("() => { const m = document.getElementById('page'); return m && !/^\\s*Loading\\./.test(m.textContent) && m.querySelector('section') }", timeout=25000)
                html = pg.eval_on_selector("#page", "e => e.innerHTML")
                img = pg.eval_on_selector('meta[property="og:image"]', "e => e.content") or ""
                snap["pages"].append({"slug": page["slug"], "title": page["title"], "description": page.get("description") or "", "image": img, "html": html})
            except Exception as e:
                errors.append("page %s: %s" % (page["slug"], e))

        try:
            pg.goto(base + "prices.html?notrack=1", wait_until="domcontentloaded")
            pg.wait_for_selector("#groups .group", timeout=25000)
            snap["prices"] = {"html": pg.eval_on_selector("#groups", "e => e.innerHTML")}
        except Exception as e:
            errors.append("prices: %s" % e)
        b.close()
    srv.shutdown()

    snap["packages"] = [{"name": x.get("name"), "price": x.get("price"), "covers": x.get("covers") or []} for x in (data.get("packages") or []) if x.get("name") and x.get("price")]
    snap["private_price"] = data.get("private_price")
    snap["classes"] = data.get("classes") or []

    snap["problems"] = [e[:300] for e in errors]
    snap["found"] = {"posts": len(posts), "pages": len(pages)}
    for e in errors:
        print("problem:", e, file=sys.stderr)
    if not snap["posts"] and not snap["pages"]:
        print("nothing rendered, keeping the old snapshot", file=sys.stderr)
        sys.exit(1)
    old = None
    if os.path.exists(OUT):
        try:
            old = json.load(open(OUT, encoding="utf-8"))
        except Exception:
            old = None
    if old and {k: v for k, v in old.items() if k != "at"} == snap:
        print("no change")
        return
    snap["at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(snap, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1, sort_keys=True)
    print("saved", len(snap["posts"]), "posts,", len(snap["pages"]), "pages, prices:", bool(snap["prices"]))


if __name__ == "__main__":
    main()
