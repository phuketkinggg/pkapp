#!/usr/bin/env python3
"""Make a store app folder for one Muay Friend gym (Android: one app per gym, named after the gym).

    python3 tools/gym_app.py <gym id from muayfriend/gyms.json> [--icon path/to/icon.png]

Writes native/apps/<id>/ (app name, app id com.muayfriend.<id>, the gym's web app address, colours, icon)
and adds it to .github/android-apps.txt so the Android workflow builds it.
The icon should be a square PNG, 1024 x 1024. Without --icon it uses the Muay App icon.
"""
import json, os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    gid = sys.argv[1]
    icon = sys.argv[sys.argv.index('--icon') + 1] if '--icon' in sys.argv else None
    gyms = json.load(open(os.path.join(ROOT, 'muayfriend', 'gyms.json'), encoding='utf-8'))
    g = next((x for x in gyms if x['id'] == gid), None)
    if not g:
        print('No gym with id', gid, 'in muayfriend/gyms.json'); sys.exit(1)
    name = re.sub(r'\s*\(.*?\)\s*$', '', g['name']).strip()
    slug = re.sub(r'[^a-z0-9]', '', gid.lower()) or 'gym'
    url = g['url'].rstrip('/') + '/'
    host = re.sub(r'^https?://', '', url).split('/')[0]
    color = g.get('color') or '#C9A24A'
    out = os.path.join(ROOT, 'native', 'apps', gid)
    os.makedirs(os.path.join(out, 'www'), exist_ok=True)
    cfg = {
        "appId": f"com.muayfriend.{slug}",
        "appName": name[:30],
        "webDir": "www",
        "server": {"url": url, "allowNavigation": [host, "muayfriend.com", "*.muayfriend.com", "*.supabase.co", "checkout.stripe.com"]},
        "ios": {"contentInset": "never", "backgroundColor": "#101311"},
        "android": {"backgroundColor": "#101311"},
    }
    json.dump(cfg, open(os.path.join(out, 'capacitor.config.json'), 'w', encoding='utf-8'), indent=2)
    page = ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
            f'<title>{name}</title><style>html,body{{margin:0;height:100%;background:#101311;color:#f2efe8;font-family:-apple-system,system-ui,sans-serif}}'
            'main{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;padding:24px;text-align:center}'
            f'button{{font:inherit;font-weight:600;padding:12px 22px;border-radius:12px;border:0;background:{color};color:#101311}}</style></head>'
            f'<body><main><h1 style="margin:0;font-size:22px">{name}</h1><p id="m">Connecting...</p><button type="button" onclick="location.href=\'{url}\'">Try again</button></main>'
            f"<script>location.replace('{url}');setTimeout(function(){{document.getElementById('m').textContent='No internet connection. Check your connection and try again.';}},6000);</script></body></html>\n")
    open(os.path.join(out, 'www', 'index.html'), 'w', encoding='utf-8').write(page)
    src = icon or os.path.join(ROOT, 'native', 'apps', 'muayapp', 'icon.png')
    shutil.copyfile(src, os.path.join(out, 'icon.png'))
    shutil.copyfile(os.path.join(ROOT, 'native', 'apps', 'muayapp', 'splash.png'), os.path.join(out, 'splash.png'))
    lst = os.path.join(ROOT, '.github', 'android-apps.txt')
    lines = open(lst, encoding='utf-8').read().splitlines()
    if gid not in [l.strip() for l in lines]:
        open(lst, 'a', encoding='utf-8').write(gid + '\n')
    print(f'Made native/apps/{gid}: "{cfg["appName"]}", {cfg["appId"]}, opens {url}')
    if not icon:
        print('Using the Muay App icon. Run again with --icon gymlogo.png (1024 x 1024) for the gym\'s own icon.')

if __name__ == '__main__':
    main()
