#!/usr/bin/env python3
"""Website languages: after tools/build_site.py, builds every page of site/ again in /ru/, /zh/, /fr/ and /de/
(the languages in pk/lang/langs.json that have translations in pk/lang/<code>.json, from tools/site_lang_pull.py).

Pages are translated here, so Google reads them in the language. pk/lang.js (with /lang/<code>.js) also translates
what the page draws later (prices, timetable, forms) and keeps links inside the language.
Adds the language addresses to the sitemap, the other-language links (hreflang) to every page, and /ru to /ru/ forwards.

  python3 tools/build_site.py && python3 tools/site_langs.py
"""
import hashlib, html, json, os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "site")
LANG_DIR = os.path.join(ROOT, "pk", "lang")
DOMAIN = "https://www.phuketking.com" if "--test" not in sys.argv else "https://new.phuketking.com"
PAGES = ["index.html", "about.html", "prices.html", "dtv.html", "shop.html", "blog.html", "post.html", "wellness.html", "beginners-muay-thai.html",
         "muay-thai-phuket.html", "train.html", "partners.html", "fighters.html", "education.html", "page.html", "404.html", "book.html"]
NOALT = ("404.html", "post.html", "page.html")
ASSET_RX = re.compile(r'((?:href|src)=")((?:site\.css|site\.js|chat\.js|reviews\.js|qrcode\.js|checkout\.js|privpick\.js|photos\.js|texts\.js|tour\.js|pano\.js)(?:\?[^"]*)?|(?:img|icons|vendor)/[^"]*)"')
SKIP_RX = re.compile(r"<(script|style)\b[\s\S]*?</\1>|<!--[\s\S]*?-->|<title>[\s\S]*?</title>", re.I)


def norm(t):
    return re.sub(r"\s+", " ", html.unescape(t)).strip()


def tr_html(src, D):
    """The page with every text between tags, alt, title, placeholder, aria-label, the page title and its descriptions in the language."""
    def text(m):
        raw = m.group(1)
        v = D.get(norm(raw))
        if not v:
            return m.group(0)
        lead = raw[:len(raw) - len(raw.lstrip())]
        trail = raw[len(raw.rstrip()):]
        return ">" + lead + html.escape(v, quote=False) + trail + "<"
    out, last = [], 0
    for m in SKIP_RX.finditer(src):
        out.append(re.sub(r">([^<>]+)<", text, src[last:m.start()]))
        blk = m.group(0)
        if blk[:6].lower() == "<title":
            v = D.get(norm(blk[blk.index(">") + 1:blk.rindex("<")]))
            if v:
                blk = "<title>" + html.escape(v, quote=False) + "</title>"
        out.append(blk)
        last = m.end()
    out.append(re.sub(r">([^<>]+)<", text, src[last:]))
    h = "".join(out)

    def attr(m):
        v = D.get(norm(m.group(2)))
        return '%s="%s"' % (m.group(1), html.escape(v, quote=True)) if v else m.group(0)
    h = re.sub(r'\b(alt|title|placeholder|aria-label)="([^"]*)"', attr, h)

    def meta(m):
        v = D.get(norm(m.group(2)))
        return m.group(1) + (html.escape(v, quote=True) if v else m.group(2)) + '"'
    return re.sub(r'(<meta (?:name|property)="(?:description|og:title|og:description)" content=")([^"]*)"', meta, h)


def lang_list():
    out = []
    for code, name, loc in json.load(open(os.path.join(LANG_DIR, "langs.json"), encoding="utf-8")):
        p = os.path.join(LANG_DIR, code + ".json")
        d = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
        if len(d) >= 50:
            out.append((code, name, loc, {norm(k): v for k, v in d.items()}))
    return out


def page_path(f):
    return "" if f == "index.html" else f[:-5]


def alternates(path, langs):
    tags = ['<link rel="alternate" hreflang="en" href="%s/%s">' % (DOMAIN, path), '<link rel="alternate" hreflang="x-default" href="%s/%s">' % (DOMAIN, path)]
    tags += ['<link rel="alternate" hreflang="%s" href="%s/%s/%s">' % ("zh-Hans" if c == "zh" else c, DOMAIN, c, path) for c, _n, _l, _d in langs]
    return "\n".join(tags)


def main():
    if not os.path.isdir(OUT):
        sys.exit("Run tools/build_site.py first.")
    langs = lang_list()
    if not langs:
        print("no website languages with translations yet")
        return
    files = [f for f in PAGES if os.path.exists(os.path.join(OUT, f))]
    snap = os.path.join(ROOT, "prerender", "snapshot.json")
    if os.path.exists(snap):
        for p in json.load(open(snap, encoding="utf-8")).get("pages", []):
            f = p["slug"] + ".html"
            if re.match(r"^[a-z0-9-]{1,80}$", p["slug"]) and os.path.exists(os.path.join(OUT, f)) and f not in files:
                files.append(f)
    paths = {page_path(f): 1 for f in files if f not in NOALT}
    paths.update({"post": 1, "page": 1})
    switch = [("en", "English")] + [(c, n) for c, n, _l, _d in langs]
    for f in files:
        if f in NOALT:
            continue
        fp = os.path.join(OUT, f)
        h = open(fp, encoding="utf-8").read()
        if 'hreflang="x-default"' not in h:
            open(fp, "w", encoding="utf-8").write(h.replace("</head>", alternates(page_path(f), langs) + "\n</head>", 1))
    shutil.copy2(os.path.join(ROOT, "pk", "lang.js"), os.path.join(OUT, "lang.js"))
    os.makedirs(os.path.join(OUT, "lang"), exist_ok=True)
    urls = []
    for code, name, loc, D in langs:
        js = "/* Website words in %s, made by tools/site_langs.py from pk/lang/%s.json. */\nwindow.PK_LANG_D=%s;\nwindow.PK_LANG_PATHS=%s;\nwindow.PK_LANGS=%s;\n" % (
            name, code, json.dumps(D, ensure_ascii=False, separators=(",", ":")), json.dumps(paths), json.dumps(switch, ensure_ascii=False))
        open(os.path.join(OUT, "lang", code + ".js"), "w", encoding="utf-8").write(js)
        ver = hashlib.md5(js.encode("utf-8")).hexdigest()[:8]
        os.makedirs(os.path.join(OUT, code), exist_ok=True)
        for f in files:
            h = open(os.path.join(OUT, f), encoding="utf-8").read()
            h = h.replace('<html lang="en">', '<html lang="%s" data-lang="%s">' % (code, code), 1)
            h = re.sub(r'<base href="/">\n?', "", h)
            h = tr_html(h, D)
            h = ASSET_RX.sub(lambda m: m.group(1) + "/" + m.group(2) + '"', h)
            h = re.sub(r"url\((img|icons)/", r"url(/\1/", h)
            # pages that are only in English keep their English address
            h = re.sub(r'href="(privacy|terms|th|muay-thai-basics|course|technique)\.html', r'href="/\1', h)
            path = page_path(f)
            h = re.sub(r'(<link rel="canonical" href=")%s/' % re.escape(DOMAIN), r"\g<1>%s/%s/" % (DOMAIN, code), h)
            h = re.sub(r'(<meta property="og:url" content=")%s/' % re.escape(DOMAIN), r"\g<1>%s/%s/" % (DOMAIN, code), h)
            h = re.sub(r'<meta property="og:locale" content="[^"]*">', '<meta property="og:locale" content="%s">' % loc, h)
            h = re.sub(r'<link rel="alternate" hreflang="[^"]*" href="[^"]*">\n?', "", h)
            if f not in NOALT:
                h = h.replace("</head>", alternates(path, langs) + "\n</head>", 1)
            h = h.replace('"inLanguage": "en"', '"inLanguage": "%s"' % code)
            tag = '<script src="/lang/%s.js?v=%s"></script>\n<script src="/lang.js?v=1"></script>\n' % (code, ver)
            i = h.find('<script src="/site.js')
            h = h[:i] + tag + h[i:] if i >= 0 else h.replace("</body>", tag + "</body>", 1)
            open(os.path.join(OUT, code, f), "w", encoding="utf-8").write(h)
            if f not in NOALT:
                urls.append("/%s/%s" % (code, path))
    # sitemap and forwards
    sm = os.path.join(OUT, "sitemap.xml")
    if os.path.exists(sm):
        x = open(sm, encoding="utf-8").read()
        day = re.search(r"<lastmod>([^<]+)</lastmod>", x)
        add = "".join("  <url><loc>%s%s</loc>%s<priority>0.6</priority></url>\n" % (DOMAIN, u, ("<lastmod>%s</lastmod>" % day.group(1)) if day else "") for u in urls)
        open(sm, "w", encoding="utf-8").write(x.replace("</urlset>", add + "</urlset>"))
    rd = os.path.join(OUT, "_redirects")
    if os.path.exists(rd):
        open(rd, "a").write("".join("/%s /%s/ 301\n" % (c, c) for c, _n, _l, _d in langs))
    print("site languages:", ", ".join("%s (%d texts)" % (c, len(d)) for c, _n, _l, d in langs), len(files), "pages each")


if __name__ == "__main__":
    main()
