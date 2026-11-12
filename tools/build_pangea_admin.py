#!/usr/bin/env python3
"""Builds the Pangea back office from the Phuket King app: the same code as app.phuketking.com, pointed at Pangea's own
database (Supabase project "Pangea Global", tqqfhahchjwihwknyiwo), with Pangea's name and colours. Written to pangea/admin/
(app.phuketking.com/pangea/admin/). Run it after changing index.html or sw.js:  python3 tools/build_pangea_admin.py
See docs/PANGEA_DATABASE.md. Never touches Phuket King data: every call goes to the Pangea project.
"""
import json, os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'pangea', 'admin')

PK_REF, PG_REF = 'jijnshwduhgegacfvpkh', 'tqqfhahchjwihwknyiwo'
PK_KEY, PG_KEY = 'sb_publishable_Y-ecbe3vlPAa6QipGHD1zQ_W-sh8V4i', 'sb_publishable_ei0gMLn3YmXoOO-3O6t_Og_qECOjLb1'

SWAPS = [
    (PK_REF, PG_REF), (PK_KEY, PG_KEY),
    ("'https://app.phuketking.com/'", "'https://app.phuketking.com/pangea/admin/'"),
    ('phuketking-backup-', 'pangea-backup-'),
    ('Phuket King Gym', 'Pangea Global Wellness'),
    ('Phuket King fighters', 'Pangea members'),
    ('PHUKET KING', 'PANGEA'),
    ('Phuket King', 'Pangea'),
    (' Work hard, Fight easy.', ''),
]
COLORS = [  # Pangea green instead of the Phuket King black buttons; the gold stays
    ('--gold:#B88A44; --gold-ink:#7A5720; --btn-bg:#101311;', '--gold:#B88A44; --gold-ink:#7A5720; --btn-bg:#18352D;'),
]


def swap(text):
    for a, b in SWAPS:
        text = text.replace(a, b)
    return text


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    html = swap(open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read())
    for a, b in COLORS:
        html = html.replace(a, b)
    html = html.replace('<title>Pangea</title>', '<title>Pangea back office</title><meta name="robots" content="noindex">', 1)
    if PK_REF in html or PK_KEY in html:
        sys.exit('The Phuket King database is still named in the Pangea back office.')
    open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(html)

    sw = swap(open(os.path.join(ROOT, 'sw.js'), encoding='utf-8').read()).replace("const CACHE = 'pk-shell-", "const CACHE = 'pg-admin-")
    open(os.path.join(OUT, 'sw.js'), 'w', encoding='utf-8').write(sw)

    man = json.load(open(os.path.join(ROOT, 'manifest.webmanifest'), encoding='utf-8'))
    man.update({'name': 'Pangea back office', 'short_name': 'Pangea team', 'description': 'Pangea Global Wellness, the team app.',
                'background_color': '#18352D', 'theme_color': '#18352D', 'start_url': './', 'scope': './'})
    json.dump(man, open(os.path.join(OUT, 'manifest.webmanifest'), 'w', encoding='utf-8'), indent=2)

    shutil.copytree(os.path.join(ROOT, 'vendor'), os.path.join(OUT, 'vendor'))
    os.makedirs(os.path.join(OUT, 'pk'), exist_ok=True)
    shutil.copy(os.path.join(ROOT, 'pk', 'privpick.js'), os.path.join(OUT, 'pk', 'privpick.js'))
    for f in ('invdoc.js', 'changelog.js', 'receipt.html', 'i18n-th.js', 'i18n-my.js'):
        src = os.path.join(ROOT, f)
        if os.path.exists(src):
            open(os.path.join(OUT, f), 'w', encoding='utf-8').write(swap(open(src, encoding='utf-8').read()))
    # Pangea's own icons, from the member app
    shutil.copytree(os.path.join(ROOT, 'pangea', 'icons'), os.path.join(OUT, 'icons'))
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import check_js
    if not check_js.check(os.path.join(OUT, 'index.html')):
        sys.exit('The build has broken JavaScript: fix the swap or the code.')
    print('Pangea back office built in pangea/admin/')


if __name__ == '__main__':
    main()
