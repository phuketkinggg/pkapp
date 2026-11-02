#!/usr/bin/env python3
"""Builds the shared Muay Friend free app (muayfriend/app/), from the Phuket King app.

One app for every free gym. Each gym is its own section (schema g_<gym>) of the shared database
"Muay Friend free" (bnglnfdgptvnmugntiom); the address says which gym: https://muayfriend.com/app/?g=<gym>.
The gym is remembered on the phone, so members can open the app from the home screen.
Same code as the other apps, with the Muay Friend brand and the free database. Run after changing index.html:
    python3 tools/build_free.py
"""
import json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_demo as bd

ROOT = bd.ROOT
OUT = os.path.join(ROOT, 'muayfriend', 'app')
FREE_REF, FREE_KEY = 'bnglnfdgptvnmugntiom', 'sb_publishable_I2cEA2hEPelGTNMwf2zWwA_98_mxHT1'

# the demo swaps, pointed at the free database and the plain Muay Friend name (each gym's own name comes from its settings)
SWAPS = [(a, b) for a, b in bd.SWAPS if a not in (bd.PK_REF, bd.PK_KEY)]
SWAPS = [(bd.PK_REF, FREE_REF), (bd.PK_KEY, FREE_KEY)] + [(a, b.replace('Muay Fight Gym', 'Muay Friend').replace('MUAY FIGHT GYM', 'MUAY FRIEND')
         .replace('muayfightgym-backup-', 'muayfriend-backup-').replace('https://muayfriend.com/demo/', 'https://muayfriend.com/app/')
         .replace('https://muayfriend.com/demo', 'https://muayfriend.com/app').replace('Muay Fight fighters', 'fighters')
         .replace('Fight Cafe', 'Cafe').replace('FIGHT CAFE', 'CAFE').replace('Camp Rooms', 'Rooms').replace('Fight Camp', 'Muay Friend')
         .replace('Chiang Mai', '')) for a, b in SWAPS]

PREBOOT = """<script>
/* Muay Friend free: which gym this is (?g=), remembered on this phone */
window.MF_MULTI=true;(function(){ var g=null,ok=/^[a-z][a-z0-9_]{1,40}$/; try{ g=new URLSearchParams(location.search).get('g'); }catch(e){}
  if(g&&ok.test(g)){ try{ localStorage.setItem('mf_gym',g); }catch(e){} } else { try{ g=localStorage.getItem('mf_gym'); }catch(e){ g=null; } }
  if(g&&ok.test(g)) window.MF_GYM=g; })();
</script>
"""


def swap(text):
    for a, b in SWAPS:
        text = text.replace(a, b)
    return text


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    html = swap(open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read())
    for a, b in bd.COLORS:
        html = html.replace(a, b)
    html = html.replace('<script src="vendor/supabase-js', PREBOOT + '<script src="vendor/supabase-js', 1)
    html = html.replace('<title>Muay Friend</title>', '<title>Muay Friend</title><meta name="robots" content="noindex">', 1)
    left = [w for w in ('phuketking', bd.PK_REF, 'Phuket King', 'Pangea', bd.DEMO_REF) if w in html]
    if left:
        sys.exit('Other app text left in the free app: ' + ', '.join(left))
    if 'window.MF_MULTI=true' not in html:
        sys.exit('The gym picker was not added.')
    open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(html)

    sw = swap(open(os.path.join(ROOT, 'sw.js'), encoding='utf-8').read()).replace("const CACHE = 'pk-shell-", "const CACHE = 'mf-free-")
    open(os.path.join(OUT, 'sw.js'), 'w', encoding='utf-8').write(sw)
    man = json.load(open(os.path.join(ROOT, 'manifest.webmanifest'), encoding='utf-8'))
    man.update({'name': 'Muay Friend', 'short_name': 'Muay Friend', 'description': 'Your gym app, by Muay Friend.',
                'background_color': '#101A2E', 'theme_color': '#101A2E'})
    json.dump(man, open(os.path.join(OUT, 'manifest.webmanifest'), 'w', encoding='utf-8'), indent=2)
    shutil.copytree(os.path.join(ROOT, 'vendor'), os.path.join(OUT, 'vendor'))
    os.makedirs(os.path.join(OUT, 'pk'), exist_ok=True)
    shutil.copy(os.path.join(ROOT, 'pk', 'privpick.js'), os.path.join(OUT, 'pk', 'privpick.js'))
    open(os.path.join(OUT, 'invdoc.js'), 'w', encoding='utf-8').write(swap(open(os.path.join(ROOT, 'invdoc.js'), encoding='utf-8').read()))
    open(os.path.join(OUT, 'changelog.js'), 'w', encoding='utf-8').write(swap(open(os.path.join(ROOT, 'changelog.js'), encoding='utf-8').read()))
    for lang in ('th', 'my'):
        src = os.path.join(ROOT, 'i18n-%s.js' % lang)
        if os.path.exists(src):
            open(os.path.join(OUT, 'i18n-%s.js' % lang), 'w', encoding='utf-8').write(swap(open(src, encoding='utf-8').read()))
    bd.OUT = OUT
    bd.icons()
    import check_js
    if not check_js.check(os.path.join(OUT, 'index.html')):
        sys.exit('The build has broken JavaScript: fix the swap or the code.')
    print('Free app built in muayfriend/app/')


if __name__ == '__main__':
    main()
