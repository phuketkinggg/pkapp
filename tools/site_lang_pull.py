#!/usr/bin/env python3
"""Website languages: brings the AI translations (edge function site-i18n) into pk/lang/<code>.json for tools/build_site.py.
Only texts still on the website (pk/lang/strings.json) are kept. Runs in the Website pre-render workflow.

  python3 tools/site_lang_pull.py
"""
import json, os, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/site-i18n?lang="
LANG = os.path.join(ROOT, "pk", "lang")

def main():
    words = set(json.load(open(os.path.join(LANG, "strings.json"), encoding="utf-8")))
    for code, _name, _loc in json.load(open(os.path.join(LANG, "langs.json"), encoding="utf-8")):
        try:
            with urllib.request.urlopen(URL + code, timeout=60) as r:
                d = json.loads(r.read().decode("utf-8"))
        except Exception as e:
            print(code, "not fetched:", e); continue
        if not isinstance(d, dict) or "error" in d:
            print(code, "not fetched:", d); continue
        d = {k: v for k, v in d.items() if k in words and isinstance(v, str) and v.strip()}
        json.dump(d, open(os.path.join(LANG, code + ".json"), "w", encoding="utf-8"), ensure_ascii=False, indent=0, sort_keys=True)
        print(code, len(d), "of", len(words), "texts")

if __name__ == "__main__":
    main()
