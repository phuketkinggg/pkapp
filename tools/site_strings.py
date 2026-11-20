#!/usr/bin/env python3
"""Website languages: lists every English text a visitor can read on the website, for translating.

Writes pk/lang/strings.json (a sorted list). The words come from the website pages in pk/ (text, alt and title texts,
page titles and descriptions), the texts the website scripts draw (prices, timetable, booking forms) and the
pre-rendered app pages, prices and timetable in prerender/snapshot.json.
The edge function site-i18n translates what is new (it reads this file from GitHub), and tools/site_lang_pull.py
brings the translations back into pk/lang/<code>.json for tools/build_site.py.

  python3 tools/site_strings.py
"""
import html, json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PK = os.path.join(ROOT, "pk")
# pages that are built in every language (legal pages and the online course pages stay in English)
PAGES = ["index.html", "about.html", "prices.html", "dtv.html", "shop.html", "blog.html", "post.html", "wellness.html", "beginners-muay-thai.html",
         "muay-thai-phuket.html", "train.html", "partners.html", "fighters.html", "education.html", "page.html", "404.html"]
SCRIPTS = ["site.js", "checkout.js", "privpick.js", "chat.js", "reviews.js", "tour.js"]
ATTR = re.compile(r'\b(alt|title|placeholder|aria-label)="([^"]*)"')
META = re.compile(r'<meta (?:name|property)="(?:description|og:title|og:description)" content="([^"]*)"')
BLOCK = re.compile(r"<(script|style)\b[\s\S]*?</\1>|<!--[\s\S]*?-->", re.I)
CODE = re.compile(r"^(https?:|mailto:|tel:|data:|#|\.|/|[a-z0-9_\-]+$|[a-z_]+\.[a-z_]+|.*[{};=<>`]|.*\\\\|.*\$\(|[A-Z_]{2,}$|.*\.(js|css|png|jpg|webp|svg|mp4|html)$)")


def norm(t):
    return re.sub(r"\s+", " ", html.unescape(t)).strip()


def keep(t):
    return len(t) >= 2 and re.search(r"[A-Za-z]", t) and not re.search(r"[฀-๿]", t)


def from_html(src, out):
    """Text between tags, outside scripts, styles and comments; alt, title, placeholder and aria-label; page title and descriptions."""
    for m in ATTR.finditer(src):
        out.add(norm(m.group(2)))
    for m in META.finditer(src):
        out.add(norm(m.group(1)))
    m = re.search(r"<title>(.*?)</title>", src, re.S)
    if m:
        out.add(norm(m.group(1)))
    body = BLOCK.sub("<x>", src)
    body = re.sub(r"<title>.*?</title>", "", body, flags=re.S)
    for t in re.findall(r">([^<>]+)<", body):
        out.add(norm(t))


def from_js(src, out):
    """Texts in quotes that read like words for people (the same test the app uses)."""
    src = re.sub(r"/\*[\s\S]*?\*/", " ", src)
    src = re.sub(r"(?m)^\s*//.*$", "", src)
    for s in re.findall(r"'((?:[^'\\\n]|\\.){1,400})'", src):
        s = s.replace("\\'", "'").replace("\\u2019", "’").replace("\\n", " ")
        t = norm(s)
        if len(t) < 2 or CODE.match(t) or not (" " in t or re.match(r"^[A-Z][a-z]", t)):
            continue
        if "<" in t:  # a piece of markup: take the words inside it
            from_html(">" + t + "<", out)
            continue
        out.add(t)


def main():
    out = set()
    for p in PAGES + ["../book.html"]:
        src = open(os.path.join(PK, p), encoding="utf-8").read()
        from_html(src, out)
        for js in re.findall(r"<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)</script>", src):
            if "application/ld+json" not in js[:80]:
                from_js(js, out)
    for f in SCRIPTS:
        if os.path.exists(os.path.join(PK, f)):
            from_js(open(os.path.join(PK, f), encoding="utf-8").read(), out)
    snap = os.path.join(ROOT, "prerender", "snapshot.json")
    if os.path.exists(snap):
        s = json.load(open(snap, encoding="utf-8"))
        for p in s.get("pages", []):
            from_html("<x>" + p.get("html", "") + "</x>", out)
            out.add(norm(p.get("title", "")))
            out.add(norm(p.get("description", "") or ""))
        if s.get("prices"):
            from_html("<x>" + s["prices"].get("html", "") + "</x>", out)
        for x in s.get("packages", []):
            out.add(norm(x.get("name", "")))
        for c in s.get("classes", []):
            out.add(norm(c.get("title", "")))
            out.add(norm(c.get("discipline", "") or ""))
    words = sorted(t for t in out if keep(t) and len(t) <= 2000)
    os.makedirs(os.path.join(PK, "lang"), exist_ok=True)
    json.dump(words, open(os.path.join(PK, "lang", "strings.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=0)
    print(len(words), "website texts in pk/lang/strings.json")


if __name__ == "__main__":
    main()
