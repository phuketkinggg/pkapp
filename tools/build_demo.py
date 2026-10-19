#!/usr/bin/env python3
"""Builds the Muay Friend demo app ("Muay Fight Gym") from the Phuket King app.

Same code as app.phuketking.com, with the brand, the database and the icons swapped,
written to muayfriend/demo/ so it is served at https://muayfriend.com/demo/.
Run it after changing index.html or sw.js:  python3 tools/build_demo.py
The demo database is the Supabase project "Muay Friend demo" (yojllgjjekitbktzblcc).
It never touches Phuket King data.
"""
import json, os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'muayfriend', 'demo')

PK_REF, DEMO_REF = 'jijnshwduhgegacfvpkh', 'yojllgjjekitbktzblcc'
PK_KEY, DEMO_KEY = 'sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i', 'sb_publishable_RSMrHUIN5CFQgUX0o_gIpw_MyogMxJX'

# One tap logins shown on the demo sign in screen. Demo database only, reset every night.
LOGINS = [
    {'label': 'Owner', 'note': 'Everything: money, staff, marketing', 'email': 'owner@demo.muayfriend.com', 'pw': 'MuayFightDemo1', 'main': True},
    {'label': 'Front desk', 'note': 'Check-ins, sales, privates', 'email': 'desk@demo.muayfriend.com', 'pw': 'MuayFightDemo1'},
    {'label': 'Coach', 'note': 'Classes, privates, coaching', 'email': 'coach@demo.muayfriend.com', 'pw': 'MuayFightDemo1'},
    {'label': 'Member', 'note': 'The app your members use', 'email': 'member@demo.muayfriend.com', 'pw': 'MuayFightDemo1'},
]

# Order matters: longer, more specific text first.
SWAPS = [
    (PK_REF, DEMO_REF), (PK_KEY, DEMO_KEY),
    ('https://www.phuketking.com', 'https://muayfriend.com'),
    ('https://app.phuketking.com/', 'https://muayfriend.com/demo/'),
    ('https://app.phuketking.com', 'https://muayfriend.com/demo'),
    ('hello@phuketking.com', 'hello@muayfriend.com'),
    ('phuketking-backup-', 'muayfightgym-backup-'),
    ('ChIJP3H551swUDARAlnVam0_73w', 'DEMO'),
    ('https://search.google.com/local/writereview?placeid=DEMO', 'https://muayfriend.com/#contact'),
    ('Phuket King Gym', 'Muay Fight Gym'),
    ('Phuket King fighters', 'Muay Fight fighters'),
    ('Phuket King', 'Muay Fight Gym'),
    ('PHUKET KING', 'MUAY FIGHT GYM'),
    ('PANGEA CAFE', 'FIGHT CAFE'),
    ('Pangea Resort', 'Camp Rooms'),
    ('Pangea Cafe', 'Fight Cafe'),
    ('Pangea cafe', 'gym cafe'),
    ('Stay at Pangea', 'Stay with us'),
    ('Pangea coaching screens', 'coaching screens'),
    ("pangea:'Pangea'", "pangea:'Coached'"),
    ("'Pangea: coached'", "'Coached: full coaching'"),
    ('Pangea', 'Fight Camp'),
    ('Kathu, Phuket', 'Chiang Mai'),
    (' Work hard, Fight easy.', ''),
    ('approved phuketking.com yet', 'approved your email domain yet'),
    ('check phuketking.com shows', 'check your domain shows'),
]

COLORS = [  # brand colours: Muay Friend red instead of Phuket King gold
    ('--gold:#B88A44; --gold-ink:#7A5720; --btn-bg:#101311;', '--gold:#D7263D; --gold-ink:#A81D30; --btn-bg:#101A2E;'),
    ('--gold:#B88A44; --gold-ink:#CFA35C; --btn-bg:#B88A44;', '--gold:#E0485C; --gold-ink:#F07A89; --btn-bg:#E0485C;'),
]


def swap(text, extra=()):
    for a, b in list(SWAPS) + list(extra):
        text = text.replace(a, b)
    return text


def icons():
    from PIL import Image, ImageDraw
    os.makedirs(os.path.join(OUT, 'icons'), exist_ok=True)

    def make(size, pad, name, rounded):
        im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        r = int(size * 0.22) if rounded else 0
        d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=(16, 26, 46, 255))
        inner = size - 2 * pad
        h = max(2, int(inner * 0.11))
        gap = int(inner * 0.2)
        top = (size - (3 * h + 2 * gap)) // 2
        for i, col in enumerate([(215, 38, 61), (236, 237, 232), (47, 91, 211)]):
            y = top + i * (h + gap)
            d.rounded_rectangle([pad, y, size - pad, y + h], radius=h // 2, fill=col + (255,))
        im.save(os.path.join(OUT, 'icons', name))

    make(192, 30, 'icon-192.png', True)
    make(512, 80, 'icon-512.png', True)
    make(512, 130, 'maskable-512.png', False)
    make(180, 28, 'apple-touch-icon.png', False)
    make(48, 8, 'favicon-48.png', True)


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    html = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
    html = swap(html, COLORS)
    logins = '<script>window.DEMO_LOGINS=' + json.dumps(LOGINS) + ';</script>\n'
    html = html.replace('<script src="vendor/supabase-js', logins + '<script src="vendor/supabase-js', 1)
    html = html.replace('<title>Muay Fight Gym</title>', '<title>Muay Fight Gym | Muay Friend demo</title><meta name="robots" content="noindex">', 1)
    left = [w for w in ('phuketking', PK_REF, 'Phuket King', 'Pangea') if w in html]
    if left:
        sys.exit('Phuket King text left in the demo: ' + ', '.join(left))
    open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(html)

    sw = open(os.path.join(ROOT, 'sw.js'), encoding='utf-8').read()
    sw = swap(sw).replace("const CACHE = 'pk-shell-", "const CACHE = 'mf-demo-")
    open(os.path.join(OUT, 'sw.js'), 'w', encoding='utf-8').write(sw)

    man = json.load(open(os.path.join(ROOT, 'manifest.webmanifest'), encoding='utf-8'))
    man.update({'name': 'Muay Fight Gym', 'short_name': 'Muay Fight', 'description': 'The Muay Friend demo gym.',
                'background_color': '#101A2E', 'theme_color': '#101A2E'})
    json.dump(man, open(os.path.join(OUT, 'manifest.webmanifest'), 'w', encoding='utf-8'), indent=2)

    shutil.copytree(os.path.join(ROOT, 'vendor'), os.path.join(OUT, 'vendor'))
    icons()
    print('Demo built in muayfriend/demo/')


if __name__ == '__main__':
    main()
