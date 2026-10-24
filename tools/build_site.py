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
ASSETS = ["site.css", "site.js", "chat.js", "reviews.js", "qrcode.js", "checkout.js", "privpick.js", "photos.js", "texts.js", "img"]

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


SNAP = os.path.join(ROOT, "prerender", "snapshot.json")
GYM = DOMAIN + "/#gym"

def esc_attr(t):
    return (t or "").replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")

def ld(obj):
    return '<script type="application/ld+json">%s</script>' % json.dumps(obj, ensure_ascii=False).replace("</", "<\\/")

def set_meta(html, attr, key, val):
    tag = '<meta %s="%s" content="%s">' % (attr, key, esc_attr(val))
    pat = re.compile(r'<meta %s="%s" content="[^"]*">' % (attr, re.escape(key)))
    return pat.sub(lambda m: tag, html, count=1) if pat.search(html) else html.replace("</head>", tag + "\n</head>", 1)

def strip_tags(t):
    t = re.sub(r"<(script|style)[\s\S]*?</\1>", " ", t)
    t = re.sub(r"<[^>]+>", " ", t)
    for a, b in (("&nbsp;", " "), ("&amp;", "&"), ("&quot;", '"'), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")):
        t = t.replace(a, b)
    return re.sub(r"\s+", " ", t).strip()

def faq_ld(html):
    qa = re.findall(r"<details><summary><h3>(.*?)</h3></summary>\s*<div[^>]*>(.*?)</div>\s*</details>", html, re.S)
    if not qa:
        return None
    return {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
        {"@type": "Question", "name": strip_tags(q), "acceptedAnswer": {"@type": "Answer", "text": strip_tags(a)}} for q, a in qa]}

def static_page(tpl, box_open, box_close, item, url, extra_ld):
    """One pre-rendered page: the normal template with the content already inside, its own title, address and data."""
    h = tpl.replace('<meta charset="utf-8">', '<meta charset="utf-8">\n<base href="/">', 1)
    title = item["title"] + " | Phuket King Muay Thai"
    h = re.sub(r"<title>.*?</title>", "<title>%s</title>" % esc_attr(title), h, count=1, flags=re.S)
    desc = item.get("description") or strip_tags(item["html"])[:155]
    h = set_meta(h, "name", "description", desc)
    h = set_meta(h, "property", "og:title", item["title"])
    h = set_meta(h, "property", "og:description", desc)
    h = set_meta(h, "property", "og:url", url)
    if item.get("image"):
        h = set_meta(h, "property", "og:image", item["image"])
    h = re.sub(r'<link rel="canonical" href="[^"]*">\n?', "", h)
    h = h.replace("</title>", '</title>\n<link rel="canonical" href="%s">' % url, 1)
    h = h.replace("</head>", "\n".join(ld(x) for x in extra_ld if x) + "\n</head>", 1)
    i = h.index(box_open)
    j = h.index(box_close, i)
    slug_attr = box_open[:-1] + ' data-slug="%s">' % item["slug"]
    return h[:i] + slug_attr + item["html"] + h[j:]

def build_static(out):
    """Blog posts and app pages as their own pages, prices with the price list inside. Returns the short addresses made."""
    if not os.path.exists(SNAP):
        return [], None
    snap = json.load(open(SNAP, encoding="utf-8"))
    taken = {p[:-5] for p in os.listdir(out) if p.endswith(".html")} | {"blog", "post", "page", "prices", "book", "pk", "img", "icons"}
    made = []
    post_tpl = open(os.path.join(out, "post.html"), encoding="utf-8").read()
    page_tpl = open(os.path.join(out, "page.html"), encoding="utf-8").read()
    crumbs = lambda name, url, mid=None: {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": i + 1, "name": n, "item": u} for i, (n, u) in enumerate([("Home", DOMAIN + "/")] + ([mid] if mid else []) + [(name, url)])]}
    for p in snap.get("posts", []):
        if p["slug"] in taken:
            continue
        url = DOMAIN + "/" + p["slug"]
        art = {"@context": "https://schema.org", "@type": "BlogPosting", "headline": p["title"], "datePublished": p.get("published"),
               "description": p.get("description") or None, "image": p.get("image") or None, "mainEntityOfPage": url, "inLanguage": "en",
               "author": {"@type": "Organization", "name": "Phuket King Muay Thai", "url": DOMAIN + "/"},
               "publisher": {"@type": "Organization", "name": "Phuket King Muay Thai", "logo": {"@type": "ImageObject", "url": DOMAIN + "/icons/icon-512.png"}}}
        art = {k: v for k, v in art.items() if v is not None}
        html = static_page(post_tpl, '<div id="post">', '</div>\n</div></article>', p, url,
                           [art, crumbs(p["title"], url, ("Blog", DOMAIN + "/blog")), faq_ld(p["html"])])
        open(os.path.join(out, p["slug"] + ".html"), "w", encoding="utf-8").write(html)
        taken.add(p["slug"]); made.append(("/" + p["slug"], "0.6"))
    for p in snap.get("pages", []):
        if p["slug"] in taken:
            continue
        url = DOMAIN + "/" + p["slug"]
        web = {"@context": "https://schema.org", "@type": "WebPage", "name": p["title"], "url": url, "description": p.get("description") or None,
               "isPartOf": {"@id": DOMAIN + "/#website"}, "about": {"@id": GYM}, "inLanguage": "en"}
        web = {k: v for k, v in web.items() if v is not None}
        html = static_page(page_tpl, '<main id="page">', '</main>', p, url, [web, crumbs(p["title"], url), faq_ld(p["html"])])
        open(os.path.join(out, p["slug"] + ".html"), "w", encoding="utf-8").write(html)
        taken.add(p["slug"]); made.append(("/" + p["slug"], "0.7"))
    # the price list inside prices.html, plus the prices as data
    pr = os.path.join(out, "prices.html")
    h = open(pr, encoding="utf-8").read()
    if snap.get("prices") and '<div id="groups">' in h:
        i = h.index('<div id="groups">'); j = h.index("</div>", i)
        h = h[:i] + '<div id="groups">' + snap["prices"]["html"] + h[j:]
    offers = [{"@type": "Offer", "name": x["name"], "price": x["price"], "priceCurrency": "THB", "availability": "https://schema.org/InStock",
               "url": DOMAIN + "/prices", "seller": {"@id": GYM}} for x in snap.get("packages", [])]
    if snap.get("private_price"):
        offers.append({"@type": "Offer", "name": "Private Muay Thai lesson, 1 hour", "price": snap["private_price"], "priceCurrency": "THB", "url": DOMAIN + "/prices", "seller": {"@id": GYM}})
    if offers:
        h = h.replace("</head>", ld({"@context": "https://schema.org", "@type": "OfferCatalog", "name": "Phuket King Muay Thai training prices", "url": DOMAIN + "/prices", "itemListElement": offers}) + "\n</head>", 1)
    open(pr, "w", encoding="utf-8").write(h)
    # the shop: products inside the page, and as product data (price, stock) for Google
    sp = os.path.join(out, "shop.html")
    h = open(sp, encoding="utf-8").read()
    if snap.get("shop") and '<div id="shop">' in h:
        i = h.index('<div id="shop">'); j = h.index("</div>", i)
        h = h[:i] + '<div id="shop" data-pre="1">' + snap["shop"]["html"] + h[j:]
    prods = []
    for x in snap.get("products", []):
        pd = {"@type": "Product", "name": x["name"], "brand": {"@type": "Brand", "name": "Phuket King Muay Thai"},
              "offers": {"@type": "Offer", "price": x["price"], "priceCurrency": "THB", "url": DOMAIN + "/shop",
                         "availability": "https://schema.org/" + ("OutOfStock" if x.get("sold_out") else "InStock"), "seller": {"@id": GYM}}}
        if x.get("image"):
            pd["image"] = x["image"]
        if x.get("description"):
            pd["description"] = x["description"][:300]
        prods.append(pd)
    if prods:
        h = h.replace("</head>", ld({"@context": "https://schema.org", "@type": "ItemList", "name": "Phuket King Muay Thai shop", "url": DOMAIN + "/shop",
                                      "itemListElement": [{"@type": "ListItem", "position": n + 1, "item": pd} for n, pd in enumerate(prods)]}) + "\n</head>", 1)
    open(sp, "w", encoding="utf-8").write(h)
    products_feed(out, snap)
    return made, snap

def products_feed(out, snap):
    """Google Merchant Center product feed (products.xml): every shop product with a photo, price in THB and stock."""
    from xml.sax.saxutils import escape as x
    items = []
    for p in snap.get("products", []):
        if not p.get("id") or not p.get("image") or (p.get("group") or "").lower().startswith("muay thai ticket"):
            continue
        desc = (p.get("description") or "").strip() or "%s from the Phuket King Muay Thai shop in Kathu, Phuket. Pick up at the gym or order online." % p["name"]
        items.append("<item><g:id>%s</g:id><g:title>%s</g:title><g:description>%s</g:description><g:link>%s</g:link><g:image_link>%s</g:image_link>"
                     "<g:availability>%s</g:availability><g:price>%s THB</g:price><g:condition>new</g:condition><g:brand>%s</g:brand><g:identifier_exists>no</g:identifier_exists>%s</item>" % (
            x(p["id"]), x(p["name"][:150]), x(desc[:4900]), x(DOMAIN + "/shop?item=" + p["id"]), x(p["image"]),
            "out_of_stock" if p.get("sold_out") else "in_stock", ("%.2f" % float(p["price"])), x("Phuket King Muay Thai"),
            ("<g:item_group_id>%s</g:item_group_id>" % x(p["group"][:50])) if p.get("group") else ""))
    open(os.path.join(out, "products.xml"), "w", encoding="utf-8").write(
        '<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0" xmlns:g="http://base.google.com/ns/1.0"><channel><title>Phuket King Muay Thai shop</title><link>%s/shop</link><description>Muay Thai gear and supplements</description>\n%s\n</channel></rss>\n' % (DOMAIN, "\n".join(items)))


def llms_txt(out, snap, made):
    """A short plain summary for AI tools (llms.txt): who we are, what it costs, when classes run, where to read more."""
    days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    L = ["# Phuket King Muay Thai", "",
         "> Technique first Muay Thai gym in Kathu, Phuket, Thailand, for complete beginners up to fighters. "
         "On a 2,000 m2 lakeside site with its own resort (Pangea Resort, lakeside bungalows), a healthy cafe and a recovery area "
         "(herbal sauna, dry sauna, steam room, ice bath, red light). Helps students with the Thailand DTV visa through Muay Thai.", "",
         "- Address: Kathu, Phuket 83120, Thailand (Google Maps: https://maps.google.com/?cid=9002483919313262850)",
         "- Email: hello@phuketking.com",
         "- WhatsApp and phone: +66 61 515 5947",
         "- Website: %s/" % DOMAIN,
         "- Booking training: %s/prices" % DOMAIN,
         "- Rooms at Pangea Resort (book direct): %s/book" % DOMAIN,
         "- DTV visa through Muay Thai: %s/dtv" % DOMAIN, ""]
    cl = [c for c in (snap.get("classes") or []) if c.get("time") and c.get("day") is not None]
    if cl:
        L += ["## Class timetable (Thailand time)", ""]
        for d in range(7):
            row = sorted([c for c in cl if c.get("day") == d], key=lambda c: c["time"])
            if row:
                L.append("- %s: %s" % (days[d], ", ".join("%s%s %s" % (c["time"], ("-" + c["end"]) if c.get("end") else "", c.get("title") or c.get("discipline") or "") for c in row)))
        L += ["- Sunday: privates only" if not any(c.get("day") == 6 for c in cl) else "", ""]
    pk = snap.get("packages") or []
    if pk or snap.get("private_price"):
        L += ["## Prices (Thai baht)", ""]
        if snap.get("private_price"):
            L.append("- Private lesson, 1 hour: %s THB" % format(int(snap["private_price"]), ","))
        L += ["- %s: %s THB" % (x["name"], format(int(x["price"]), ",")) for x in pk]
        L += ["", "Card payments carry a card fee. Prices are kept up to date at %s/prices" % DOMAIN, ""]
    if snap.get("posts"):
        L += ["## Guides", ""] + ["- [%s](%s/%s)%s" % (p["title"], DOMAIN, p["slug"], (": " + p["description"]) if p.get("description") else "") for p in snap["posts"] if ("/" + p["slug"], "0.6") in made] + [""]
    pages = [p for p in snap.get("pages", []) if ("/" + p["slug"], "0.7") in made]
    if pages:
        L += ["## Pages", ""] + ["- [%s](%s/%s)%s" % (p["title"], DOMAIN, p["slug"], (": " + p["description"]) if p.get("description") else "") for p in pages] + [""]
    L += ["## More", "", "- [About](%s/about)" % DOMAIN, "- [Wellness and recovery](%s/wellness)" % DOMAIN, "- [Online courses](%s/courses)" % DOMAIN, "- [Shop](%s/shop)" % DOMAIN, "- [Blog](%s/blog)" % DOMAIN]
    open(os.path.join(out, "llms.txt"), "w", encoding="utf-8").write("\n".join(x for x in L if x is not None).replace("\n\n\n", "\n\n") + "\n")

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
    for f in ("resort-aerial.jpg", "mango-grove-5.mp4", "mango-grove-5.jpg"):
        shutil.copy2(os.path.join(ROOT, "img", f), os.path.join(OUT, "img", f))
    made, snap = build_static(OUT)
    if snap and LIVE:
        llms_txt(OUT, snap, made)
    short = {u[1:] for u, _ in made}
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
        # old service pages and WordPress system addresses seen in Website numbers
        "/services/* /prices 301", "/services /prices 301", "/wp-json/* / 301", "/wp-content/* / 301", "/wp-admin/* / 301", "/wp-login.php / 301",
        "/muay-thai /prices 301", "/muay-thai/ /prices 301", "/private-lessons /prices 301", "/private-lessons/ /prices 301",
        # more old WordPress addresses Google still sends people to (Search Console, Oct 2026)
        "/team/* /about 301", "/contact /#location 301", "/contact/ /#location 301",
        "/search-availability /book 301", "/search-availability/ /book 301", "/search-availability-2 /book 301", "/search-availability-2/ /book 301",
        "/accommodation/* /book 301", "/accommodations/* /book 301", "/accommodation-category/* /book 301", "/accommodation-tag/* /book 301", "/accommodation-facility/* /book 301",
        "/my-account1 " + APP + " 301", "/my-account1/ " + APP + " 301", "/blog/page/* /blog 301", "/schedule/* /#schedule 301", "/home. / 301",
    ]
    slugs = json.load(open(os.path.join(ROOT, "tools", "blog_slugs.json"))) if os.path.exists(os.path.join(ROOT, "tools", "blog_slugs.json")) else []
    for s in slugs:
        r += ["/%s/ /%s 301" % (s, s)] if s in short else ["/%s /post?p=%s 301" % (s, s), "/%s/ /post?p=%s 301" % (s, s)]
    r += ["/%s/ /%s 301" % (s, s) for s in sorted(short) if s not in slugs]
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
    # blog posts and app pages too (copied from the live sitemap into tools/sitemap_extra.txt), so Google sees them on the main sitemap
    urls += [m for m in made if m[0] not in {u for u, _ in urls}]
    ex = os.path.join(ROOT, "tools", "sitemap_extra.txt")
    if os.path.exists(ex) and not made:
        for line in open(ex, encoding="utf-8"):
            u = line.strip().replace(DOMAIN, "")
            if u.startswith("/") and "&" not in u and "<" not in u and all(u != x[0] for x in urls):
                urls.append((u, "0.7" if u.startswith("/page") else "0.6"))
    open(os.path.join(OUT, "sitemap.xml"), "w").write('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join("  <url><loc>%s%s</loc><lastmod>%s</lastmod><priority>%s</priority></url>\n" % (DOMAIN, u, today, pr) for u, pr in urls) + "</urlset>\n")
    print("site/ built", "(live, Google allowed)" if LIVE else "(test, hidden from Google)", len(r), "forwards")

main()
