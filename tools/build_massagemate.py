#!/usr/bin/env python3
"""Builds the Massage Mate demo app ("Massage Mate Demo Spa") from the Phuket King app.

Same code as app.phuketking.com, run in spa mode (window.SHOP_TYPE='spa'), with the brand, the database and the icons swapped,
written to massagemate/demo/. Run it after changing index.html or sw.js:  python3 tools/build_massagemate.py
The demo database is the Supabase project "Massage Mate demo" (phjekupadmjwzrocahiv). It never touches Phuket King data.
"""
import json, os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'massagemate', 'demo')

PK_REF, MM_REF = 'jijnshwduhgegacfvpkh', 'phjekupadmjwzrocahiv'
PK_KEY, MM_KEY = 'sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i', 'sb_publishable_lbQ8bwEF3IvTt1NSIRa3uA_WWFgUCne'

LOGINS = [
    {'label': 'Owner', 'note': 'Everything: board, money, staff, menu', 'email': 'owner@demo.massagemate.app', 'pw': 'MassageMateDemo1', 'main': True},
    {'label': 'Front desk', 'note': 'Board, walk-ins, bookings, till', 'email': 'desk@demo.massagemate.app', 'pw': 'MassageMateDemo1'},
    {'label': 'Therapist', 'note': 'My day, clock in, my money', 'email': 'therapist@demo.massagemate.app', 'pw': 'MassageMateDemo1'},
    {'label': 'Customer', 'note': 'Book a treatment', 'email': 'guest@demo.massagemate.app', 'pw': 'MassageMateDemo1'},
]

SWAPS = [
    (PK_REF, MM_REF), (PK_KEY, MM_KEY),
    ('https://www.phuketking.com', 'https://massagemate.app'),
    ('https://app.phuketking.com/', './'),
    ('https://app.phuketking.com', '.'),
    ('hello@phuketking.com', 'hello@massagemate.app'),
    ('phuketking-backup-', 'massagemate-backup-'),
    ('ChIJP3H551swUDARAlnVam0_73w', 'DEMO'),
    ('https://search.google.com/local/writereview?placeid=DEMO', 'https://massagemate.app/'),
    ('Phuket King Gym', 'Massage Mate Demo Spa'),
    ('Phuket King fighters', 'regular customers'),
    ('Phuket King', 'Massage Mate Demo Spa'),
    ('PHUKET KING', 'MASSAGE MATE'),
    ('PANGEA CAFE', 'TEA CORNER'),
    ('Pangea Resort', 'Guest Rooms'),
    ('Pangea Cafe', 'Tea Corner'),
    ('Pangea cafe', 'tea corner'),
    ('Stay at Pangea', 'Stay with us'),
    ('Pangea coaching screens', 'coaching screens'),
    ("pangea:'Pangea'", "pangea:'VIP'"),
    ("'Pangea: coached'", "'VIP: full care'"),
    ('Pangea', 'Spa'),
    ('Kathu, Phuket', 'Patong, Phuket'),
    (' Work hard, Fight easy.', ''),
    ('approved phuketking.com yet', 'approved your email domain yet'),
    ('check phuketking.com shows', 'check your domain shows'),
    ('phuketking.com', 'massagemate.app'),
]

COLORS = [  # brand colours: Massage Mate teal instead of Phuket King gold
    ('--gold:#B88A44; --gold-ink:#7A5720; --btn-bg:#101311;', '--gold:#2E8B7A; --gold-ink:#1F6B5D; --btn-bg:#16352F;'),
    ('--gold:#B88A44; --gold-ink:#CFA35C; --btn-bg:#B88A44;', '--gold:#4DB3A0; --gold-ink:#7FCCBD; --btn-bg:#4DB3A0;'),
]


def swap(text, extra=()):
    for a, b in list(SWAPS) + list(extra):
        text = text.replace(a, b)
    return text


def icons():
    from PIL import Image, ImageDraw
    os.makedirs(os.path.join(OUT, 'icons'), exist_ok=True)

    def make(size, pad, name, rounded):
        big = size * 4
        im = Image.new('RGBA', (big, big), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        r = int(big * 0.22) if rounded else 0
        d.rounded_rectangle([0, 0, big - 1, big - 1], radius=r, fill=(46, 139, 122, 255))
        p = pad * 4
        c = big / 2
        w = (big - 2 * p)
        # three petals: a simple lotus
        d.ellipse([c - w * 0.13, p + w * 0.08, c + w * 0.13, p + w * 0.78], fill=(255, 255, 255, 255))
        for sgn in (-1, 1):
            pts = [(c + sgn * w * 0.04, p + w * 0.80), (c + sgn * w * 0.44, p + w * 0.30), (c + sgn * w * 0.40, p + w * 0.62)]
            d.polygon(pts, fill=(255, 255, 255, 235))
        d.rounded_rectangle([c - w * 0.42, p + w * 0.80, c + w * 0.42, p + w * 0.86], radius=int(w * 0.03), fill=(255, 255, 255, 255))
        im.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, 'icons', name))

    make(192, 34, 'icon-192.png', True)
    make(512, 90, 'icon-512.png', True)
    make(512, 140, 'maskable-512.png', False)
    make(180, 30, 'apple-touch-icon.png', False)
    make(48, 8, 'favicon-48.png', True)


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    html = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
    html = swap(html, COLORS)
    pre = '<script>window.SHOP_TYPE="spa";window.DEMO_BRAND="Massage Mate";window.DEMO_HOME="./";window.DEMO_LOGINS=' + json.dumps(LOGINS) + ';</script>\n'
    html = html.replace('<script src="vendor/supabase-js', pre + '<script src="vendor/supabase-js', 1)
    html = html.replace('<title>Massage Mate Demo Spa</title>', '<title>Massage Mate Demo Spa | Massage Mate demo</title><meta name="robots" content="noindex">', 1)
    left = [w for w in ('phuketking', PK_REF, 'Phuket King', 'Pangea') if w in html]
    if left:
        sys.exit('Phuket King text left in the Massage Mate demo: ' + ', '.join(left))
    open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(html)

    sw = open(os.path.join(ROOT, 'sw.js'), encoding='utf-8').read()
    sw = swap(sw).replace("const CACHE = 'pk-shell-", "const CACHE = 'mm-demo-")
    open(os.path.join(OUT, 'sw.js'), 'w', encoding='utf-8').write(sw)

    man = json.load(open(os.path.join(ROOT, 'manifest.webmanifest'), encoding='utf-8'))
    man.update({'name': 'Massage Mate Demo Spa', 'short_name': 'Massage Mate', 'description': 'The Massage Mate demo spa.',
                'background_color': '#16352F', 'theme_color': '#16352F'})
    json.dump(man, open(os.path.join(OUT, 'manifest.webmanifest'), 'w', encoding='utf-8'), indent=2)

    shutil.copytree(os.path.join(ROOT, 'vendor'), os.path.join(OUT, 'vendor'))
    os.makedirs(os.path.join(OUT, 'pk'), exist_ok=True)
    shutil.copy(os.path.join(ROOT, 'pk', 'privpick.js'), os.path.join(OUT, 'pk', 'privpick.js'))
    open(os.path.join(OUT, 'invdoc.js'), 'w', encoding='utf-8').write(swap(open(os.path.join(ROOT, 'invdoc.js'), encoding='utf-8').read()))
    icons()
    print('Massage Mate demo built in massagemate/demo/')


if __name__ == '__main__':
    main()
