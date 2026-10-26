#!/usr/bin/env python3
"""App languages: builds i18n-th.js and i18n-my.js from i18n/strings.json (English -> [Thai, Myanmar]).

The app looks up every text it draws in these files (see uiApply in index.html). Fixes made in the app
(Settings, Languages) are kept in the database and win over these.
  python3 tools/build_i18n.py            build the two files
  python3 tools/build_i18n.py --missing  list app texts that have no translation yet (add them to i18n/strings.json)
"""
import json, os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'i18n', 'strings.json')

CLASSY = set('panel pad row btn small primary chip sub lrow ctab ctabs danger wrap narrow static scroll dialog pvok notr warn ok bad out up down'.split())

def app_texts():
    src = open(os.path.join(ROOT, 'index.html'), encoding='utf-8').read()
    body = src[src.index('<script'):]
    body = re.sub(r'/\*[\s\S]*?\*/', ' ', body)
    body = re.sub(r'(?m)^\s*//.*$', '', body)
    code = re.compile(r"^(https?:|mailto:|tel:|data:|#|\.|/|[a-z0-9_\-]+$|[a-z_]+\.[a-z_]+|.*[{};=<>`]|.*\\\\|.*\$\(|[A-Z_]{2,}$|.*\.(js|css|png|jpg|webp|svg|mp4)$)")
    out = []
    for s in re.findall(r"'((?:[^'\\\n]|\\.){1,400})'", body):
        s = s.replace("\\'", "'").replace('\\n', '\n').replace('\\u2019', '’')
        t = s.strip()
        if len(t) < 2 or not re.search(r'[A-Za-z]', t) or code.match(t) or re.search(r'[฀-๿က-႟]', t): continue
        if not (' ' in t or re.match(r'^[A-Z][a-z]', t)) or re.match(r'^[a-z]+(-[a-z]+)+$', t): continue
        if re.match(r'^[a-z0-9 _-]+$', t) and set(t.split()) & CLASSY: continue  # css class names
        out.append(s)
    return out

def main():
    data = json.load(open(SRC, encoding='utf-8'))
    if '--missing' in sys.argv:
        have = {k.strip() for k in data}
        miss = sorted({s for s in app_texts() if s.strip() not in have})
        print('\n'.join(miss)); print(len(miss), 'missing', file=sys.stderr); return
    for i, l in enumerate(['th', 'my']):
        d, p = {}, {}
        for en, tr in data.items():
            k, v = en.strip(), (tr[i] if isinstance(tr, list) and len(tr) > i else '').strip()
            if not k or not v or v == k or not re.search(r'[A-Za-z]', k): continue
            v = v.replace('—', ', ').replace(' & ', ' และ ' if l == 'th' else ' နှင့် ')
            d[k] = v
            if en != k or re.match(r'^[,.:;(]', k) or re.search(r'[,:(]$', k): p[k] = 1
        js = '/* App words in %s, made by tools/build_i18n.py from i18n/strings.json. Do not edit by hand. */\nwindow.I18N_%s=%s;\n' % ('Thai' if l == 'th' else 'Myanmar', l, json.dumps({'d': d, 'p': p}, ensure_ascii=False, separators=(',', ':')))
        open(os.path.join(ROOT, 'i18n-%s.js' % l), 'w', encoding='utf-8').write(js)
        print(l, len(d), 'texts,', len(p), 'pieces')

if __name__ == '__main__':
    main()
