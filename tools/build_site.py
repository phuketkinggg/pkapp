#!/usr/bin/env python3
"""Builds the public website into site/ for Cloudflare Pages (new.phuketking.com now, www.phuketking.com on switch day).

The pages are written in pk/ (and book.html), where they also run as test pages next to the app on GitHub.
This copies them into site/ with the links fixed for a website that lives at the root of its own address,
adds the forwarding for old WordPress addresses (_redirects), robots.txt and sitemap.xml.

Run after changing any website page:   python3 tools/build_site.py
Hidden test build (no Google):         python3 tools/build_site.py --test
"""
import os, re, shutil, sys, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "site")
# the website is live on www.phuketking.com since 19 Oct 2026; --test builds the hidden test version
LIVE = "--test" not in sys.argv
APP = "https://app.phuketking.com/"
DOMAIN = "https://www.phuketking.com" if LIVE else "https://new.phuketking.com"
PAGES = ["index.html", "about.html", "prices.html", "dtv.html", "shop.html", "blog.html", "post.html", "wellness.html", "courses.html", "course.html", "page.html", "privacy.html", "404.html"]
ASSETS = ["site.css", "site.js", "chat.js", "reviews.js", "qrcode.js", "checkout.js", "photos.js", "texts.js", "img"]

def fix_pk(html):
    html = html.replace('href="../book.html"', 'href="book.html"')
    html = html.replace('"../icons/', '"icons/').replace("(../icons/", "(icons/")
    html = html.replace('"../img/', '"img/').replace("(../img/", "(img/")
    html = re.sub(r'href="\.\./"', 'href="%s"' % APP, html)
    return html

def fix_book(html):
    html = html.replace('href="pk/', 'href="').replace('src="pk/', 'src="')
    return html

NAMES = {"about.html": "About", "prices.html": "Prices", "dtv.html": "DTV Visa", "shop.html": "Shop", "blog.html": "Blog", "wellness.html": "Wellness and recovery",
         "courses.html": "Online courses", "book.html": "Stay at Pangea Resort", "privacy.html": "Privacy policy"}
DYNAMIC = ("post.html", "page.html", "course.html", "404.html")
DEFAULT_IMG = "https://jijnshwduhgegacfvpkh.supabase.co/storage/v1/object/public/promos/site/default/home_hero.webp"

def seo(html, page):
    """Share previews, fonts preconnect, breadcrumbs and FAQ data for Google, added to every page the same way."""
    def get(pat):
        m = re.search(pat, html, re.S)
        return m.group(1) if m else ""
    title, desc = get(r"<title>(.*?)</title>"), get(r'<meta name="description" content="([^"]*)"')
    path = "/" if page == "index.html" else "/" + page[:-5]
    url = DOMAIN + path
    # og:image must be a full address
    html = re.sub(r'(<meta property="og:image" content=")(?!https?://)([^"]+)"', lambda m: m.group(1) + DOMAIN + "/" + m.group(2).lstrip("./") + '"', html)
    tags = []
    def need(prop, val, attr="property"):
        if val and ('%s="%s"' % (attr, prop)) not in html:
            tags.append('<meta %s="%s" content="%s">' % (attr, prop, val))
    need("og:title", title.split(" | ")[0] if " | " in title else title)
    need("og:description", desc)
    need("og:image", DEFAULT_IMG)
    need("og:type", "website")
    need("og:site_name", "Phuket King Muay Thai")
    need("og:locale", "en_GB")
    if page not in DYNAMIC:
        need("og:url", url)
    need("twitter:card", "summary_large_image", "name")
    if 'rel="preconnect"' not in html:
        tags.append('<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>')
    if page in NAMES:
        tags.append('<script type="application/ld+json">%s</script>' % json.dumps({"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Home", "item": DOMAIN + "/"}, {"@type": "ListItem", "position": 2, "name": NAMES[page], "item": url}]}))
    # questions and answers on the page become FAQ data, unless the page already has it
    if '"FAQPage"' not in html and page not in DYNAMIC:
        qa = re.findall(r"<details><summary><h3>(.*?)</h3></summary>\s*<p>(.*?)</p>", html, re.S)
        if qa:
            strip = lambda t: re.sub(r"<[^>]+>", "", t).strip()
            tags.append('<script type="application/ld+json">%s</script>' % json.dumps({"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
                {"@type": "Question", "name": strip(q), "acceptedAnswer": {"@type": "Answer", "text": strip(a)}} for q, a in qa]}))
    if tags:
        html = html.replace("</head>", "\n".join(tags) + "\n</head>", 1)
    return html

def finish(html, page=None):
    # tell Google the one true address of each page
    if page and '<link rel="canonical"' not in html:
        path = "/" if page == "index.html" else "/" + page[:-5]
        if page not in DYNAMIC:
            html = html.replace("</title>", "</title>\n<link rel=\"canonical\" href=\"%s%s\">" % (DOMAIN, path), 1)
    if page:
        html = seo(html, page)
    if LIVE and page != "404.html":
        html = html.replace('<meta name="robots" content="noindex">\n', '').replace('<meta name="robots" content="noindex">', '')
    return html

def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    for p in PAGES:
        src = open(os.path.join(ROOT, "pk", p), encoding="utf-8").read()
        open(os.path.join(OUT, p), "w", encoding="utf-8").write(finish(fix_pk(src), p))
    for a in ASSETS:
        s = os.path.join(ROOT, "pk", a)
        (shutil.copytree if os.path.isdir(s) else shutil.copy2)(s, os.path.join(OUT, a))
    # site.css points at ../icons and ../img
    css = os.path.join(OUT, "site.css")
    txt = open(css, encoding="utf-8").read().replace("../icons/", "icons/").replace("../img/", "img/")
    open(css, "w", encoding="utf-8").write(txt)
    book = open(os.path.join(ROOT, "book.html"), encoding="utf-8").read()
    open(os.path.join(OUT, "book.html"), "w", encoding="utf-8").write(finish(fix_book(book), "book.html"))
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
        # common WordPress addresses, so old links and Google results land somewhere useful
        "/home /  301", "/home/ / 301", "/index.php / 301", "/feed /blog 301", "/feed/* /blog 301", "/comments/feed /blog 301",
        "/category/* /blog 301", "/tag/* /blog 301", "/author/* /blog 301", "/page/* /blog 301",
        "/wellness /wellness 200", "/recovery /wellness 301", "/recovery/ /wellness 301", "/spa /wellness 301", "/spa/ /wellness 301",
        "/courses/ /courses 301", "/visa /dtv 301", "/visa/ /dtv 301",
    ]
    slugs = json.load(open(os.path.join(ROOT, "tools", "blog_slugs.json"))) if os.path.exists(os.path.join(ROOT, "tools", "blog_slugs.json")) else []
    for s in slugs:
        r += ["/%s /post?p=%s 301" % (s, s), "/%s/ /post?p=%s 301" % (s, s)]
    r = [x.replace("  ", " ") for x in r if not x.startswith("/blog /blog 200") and not x.startswith("/wellness /wellness 200")]
    open(os.path.join(OUT, "_redirects"), "w").write("\n".join(r) + "\n")
    # security headers for every page (Cloudflare Pages reads this file)
    open(os.path.join(OUT, "_headers"), "w").write("""/*
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  X-Content-Type-Options: nosniff
  X-Frame-Options: SAMEORIGIN
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(self)
  Content-Security-Policy: frame-ancestors 'self'
""")
    if LIVE:
        open(os.path.join(OUT, "robots.txt"), "w").write("User-agent: *\nAllow: /\nSitemap: %s/sitemap.xml\nSitemap: https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/sitemap\n" % DOMAIN)
    else:
        open(os.path.join(OUT, "robots.txt"), "w").write("User-agent: *\nDisallow: /\n")
    # main pages here; blog posts, courses and pages made in the app are in the live sitemap (listed in robots.txt)
    import datetime
    today = datetime.date.today().isoformat()
    urls = [("/", "1.0"), ("/prices", "0.9"), ("/book", "0.9"), ("/dtv", "0.8"), ("/about", "0.7"), ("/wellness", "0.7"), ("/courses", "0.6"), ("/shop", "0.6"), ("/blog", "0.6")]
    open(os.path.join(OUT, "sitemap.xml"), "w").write('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join("  <url><loc>%s%s</loc><lastmod>%s</lastmod><priority>%s</priority></url>\n" % (DOMAIN, u, today, pr) for u, pr in urls) + "</urlset>\n")
    print("site/ built", "(live, Google allowed)" if LIVE else "(test, hidden from Google)", len(r), "forwards")

main()
