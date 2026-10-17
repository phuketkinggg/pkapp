#!/usr/bin/env python3
"""Builds the public website into site/ for Cloudflare Pages (new.phuketking.com now, www.phuketking.com on switch day).

The pages are written in pk/ (and book.html), where they also run as test pages next to the app on GitHub.
This copies them into site/ with the links fixed for a website that lives at the root of its own address,
adds the forwarding for old WordPress addresses (_redirects), robots.txt and sitemap.xml.

Run after changing any website page:   python3 tools/build_site.py
On switch day, to let Google in:       python3 tools/build_site.py --live
"""
import os, re, shutil, sys, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "site")
LIVE = "--live" in sys.argv
APP = "https://app.phuketking.com/"
DOMAIN = "https://www.phuketking.com" if LIVE else "https://new.phuketking.com"
PAGES = ["index.html", "about.html", "prices.html", "dtv.html", "shop.html", "blog.html", "post.html"]
ASSETS = ["site.css", "site.js", "photos.js", "texts.js", "img"]

def fix_pk(html):
    html = html.replace('href="../book.html"', 'href="book.html"')
    html = html.replace('"../icons/', '"icons/').replace("(../icons/", "(icons/")
    html = html.replace('"../img/', '"img/').replace("(../img/", "(img/")
    html = re.sub(r'href="\.\./"', 'href="%s"' % APP, html)
    return html

def fix_book(html):
    html = html.replace('href="pk/', 'href="').replace('src="pk/', 'src="')
    return html

def finish(html):
    if LIVE:
        html = html.replace('<meta name="robots" content="noindex">\n', '').replace('<meta name="robots" content="noindex">', '')
    return html

def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    for p in PAGES:
        src = open(os.path.join(ROOT, "pk", p), encoding="utf-8").read()
        open(os.path.join(OUT, p), "w", encoding="utf-8").write(finish(fix_pk(src)))
    for a in ASSETS:
        s = os.path.join(ROOT, "pk", a)
        (shutil.copytree if os.path.isdir(s) else shutil.copy2)(s, os.path.join(OUT, a))
    # site.css points at ../icons and ../img
    css = os.path.join(OUT, "site.css")
    txt = open(css, encoding="utf-8").read().replace("../icons/", "icons/").replace("../img/", "img/")
    open(css, "w", encoding="utf-8").write(txt)
    book = open(os.path.join(ROOT, "book.html"), encoding="utf-8").read()
    open(os.path.join(OUT, "book.html"), "w", encoding="utf-8").write(finish(fix_book(book)))
    os.makedirs(os.path.join(OUT, "icons"))
    for f in ["icon-192.png", "icon-512.png", "favicon-48.png", "apple-touch-icon.png"]:
        if os.path.exists(os.path.join(ROOT, "icons", f)):
            shutil.copy2(os.path.join(ROOT, "icons", f), os.path.join(OUT, "icons", f))
    shutil.copy2(os.path.join(ROOT, "img", "resort-aerial.jpg"), os.path.join(OUT, "img", "resort-aerial.jpg"))
    # old WordPress addresses forward permanently to the new pages (Cloudflare Pages reads this file)
    r = [
        "/about-us /about 301", "/about-us/ /about 301", "/team /#coaches 301", "/team/ /#coaches 301",
        "/schedule /#schedule 301", "/schedule/ /#schedule 301", "/pricing /prices 301", "/pricing/ /prices 301",
        "/accommodations /book 301", "/accommodations/ /book 301", "/accommodation /book 301", "/accommodation/ /book 301",
        "/5-year-dvt-visa /dtv 301", "/5-year-dvt-visa/ /dtv 301", "/dtv-visa /dtv 301", "/dtv-visa/ /dtv 301",
        "/blog /blog 200", "/blog/ /blog 301", "/contact-us /#location 301", "/contact-us/ /#location 301",
        "/shop/* /shop 301", "/product/* /shop 301", "/product-category/* /shop 301", "/cart /shop 301", "/cart/ /shop 301",
        "/checkout /shop 301", "/checkout/ /shop 301", "/my-account " + APP + " 301", "/my-account/* " + APP + " 301",
    ]
    slugs = json.load(open(os.path.join(ROOT, "tools", "blog_slugs.json"))) if os.path.exists(os.path.join(ROOT, "tools", "blog_slugs.json")) else []
    for s in slugs:
        r += ["/%s /post?p=%s 301" % (s, s), "/%s/ /post?p=%s 301" % (s, s)]
    r = [x for x in r if not x.startswith("/blog /blog 200")]
    open(os.path.join(OUT, "_redirects"), "w").write("\n".join(r) + "\n")
    if LIVE:
        open(os.path.join(OUT, "robots.txt"), "w").write("User-agent: *\nAllow: /\nSitemap: %s/sitemap.xml\n" % DOMAIN)
    else:
        open(os.path.join(OUT, "robots.txt"), "w").write("User-agent: *\nDisallow: /\n")
    urls = ["/", "/about", "/prices", "/dtv", "/book", "/shop", "/blog"] + ["/post?p=" + s for s in slugs]
    open(os.path.join(OUT, "sitemap.xml"), "w").write('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join("  <url><loc>%s%s</loc></url>\n" % (DOMAIN, u.replace("&", "&amp;")) for u in urls) + "</urlset>\n")
    print("site/ built", "(live, Google allowed)" if LIVE else "(test, hidden from Google)", len(r), "forwards")

main()
