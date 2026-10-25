#!/usr/bin/env python3
"""Checks the JavaScript in an app page with node --check, so a broken build never goes out unnoticed.
Used by the build scripts; run on its own:  python3 tools/check_js.py index.html massagemate/demo/index.html"""
import re, shutil, subprocess, sys, tempfile, os

def check(path):
    if not shutil.which('node'):
        print('node not found: JavaScript not checked for', path); return True
    html = open(path, encoding='utf-8').read()
    code = '\n;\n'.join(re.findall(r'<script>(.*?)</script>', html, re.S))
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as f:
        f.write(code); name = f.name
    r = subprocess.run(['node', '--check', name], capture_output=True, text=True); os.unlink(name)
    if r.returncode:
        print('BROKEN JavaScript in', path); print(r.stderr[:1500]); return False
    return True

if __name__ == '__main__':
    ok = all([check(p) for p in (sys.argv[1:] or ['index.html'])])
    sys.exit(0 if ok else 1)
