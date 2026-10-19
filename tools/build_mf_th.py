#!/usr/bin/env python3
"""Builds the Thai Muay Friend page (muayfriend/th/index.html).

The look (head and styles) comes from muayfriend/index.html, so design changes carry over.
The Thai words live in tools/mf_th_body.html. Run after changing either:  python3 tools/build_mf_th.py
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
en = open(os.path.join(ROOT, 'muayfriend', 'index.html'), encoding='utf-8').read()
body = open(os.path.join(ROOT, 'tools', 'mf_th_body.html'), encoding='utf-8').read()
head = en[:en.index('<body>')]

def rep(a, b):
    global head
    if a not in head:
        sys.exit('Not found in the English page: ' + a[:80])
    head = head.replace(a, b)

TITLE = 'Muay Friend | แอปบริหารยิมมวยไทย ครบในแอปเดียว'
DESC = 'แอปเดียวสำหรับบริหารยิมมวยไทย: การจอง เช็คอิน งานขาย คาเฟ่ การโค้ช บัญชี และเว็บไซต์ของคุณ สร้างร่วมกับยิมกว่า 30 แห่งทั่วโลก'
rep('<html lang="en">', '<html lang="th">')
head = re.sub(r'<title>.*?</title>', '<title>' + TITLE + '</title>', head)
head = re.sub(r'<meta name="description" content="[^"]*">', '<meta name="description" content="' + DESC + '">', head)
head = re.sub(r'<meta property="og:title" content="[^"]*">', '<meta property="og:title" content="' + TITLE + '">', head)
head = re.sub(r'<meta property="og:description" content="[^"]*">', '<meta property="og:description" content="' + DESC + '">', head)
rep('<link rel="canonical" href="https://muayfriend.com/">', '<link rel="canonical" href="https://muayfriend.com/th/">')
rep('<meta property="og:url" content="https://muayfriend.com/">', '<meta property="og:url" content="https://muayfriend.com/th/">\n<meta property="og:locale" content="th_TH">')
head = head.replace('url(fonts/', 'url(../fonts/').replace('href="fonts/', 'href="../fonts/').replace('href="favicon.svg"', 'href="../favicon.svg"')
head = head.replace('"url":"https://muayfriend.com/"', '"url":"https://muayfriend.com/th/","inLanguage":"th"')

THAI = '''@font-face{font-family:'Noto Sans Thai';font-style:normal;font-weight:400;font-display:swap;src:url(../fonts/noto-sans-thai-thai-400-normal.woff2) format('woff2');unicode-range:U+0E01-0E5B,U+200C-200D,U+25CC}
@font-face{font-family:'Noto Sans Thai';font-style:normal;font-weight:600;font-display:swap;src:url(../fonts/noto-sans-thai-thai-600-normal.woff2) format('woff2');unicode-range:U+0E01-0E5B,U+200C-200D,U+25CC}
@font-face{font-family:'Noto Sans Thai';font-style:normal;font-weight:800;font-display:swap;src:url(../fonts/noto-sans-thai-thai-800-normal.woff2) format('woff2');unicode-range:U+0E01-0E5B,U+200C-200D,U+25CC}
/* Thai: Thai letters use Noto Sans Thai; taller lines so vowels and tone marks are not cut off */
:root{--display:'Big Shoulders Display','Noto Sans Thai',sans-serif;--body:'Instrument Sans','Noto Sans Thai',system-ui,sans-serif}
body{line-height:1.75}
h1,h2,h3{line-height:1.3;letter-spacing:0}
h2{font-size:clamp(32px,4.6vw,52px)}
h3{font-size:24px}
.hero h1{font-size:clamp(40px,5.6vw,74px);line-height:1.2;text-transform:none}
.hero h1 span{white-space:normal!important}
.instead h2{font-size:40px}
.feat h3{font-size:30px}
.mlist b{font-size:20px}
.done h3{font-size:32px}
.lede{max-width:38em}
'''
head = head.replace('</style>', THAI + '</style>')
out = os.path.join(ROOT, 'muayfriend', 'th')
os.makedirs(out, exist_ok=True)
html = head + body
if '—' in html or '–' in html:
    sys.exit('Long dash found in the Thai page.')
open(os.path.join(out, 'index.html'), 'w', encoding='utf-8').write(html)
print('Thai page built in muayfriend/th/')
