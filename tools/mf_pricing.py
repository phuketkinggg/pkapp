#!/usr/bin/env python3
"""Builds the Prices section of the Muay Friend site (English page and the Thai body), from the data below.
Plans, prices, what each plan has, the website pages per plan and the yearly offer all live here.
Run after a change:  python3 tools/mf_pricing.py && python3 tools/build_mf_th.py
"""
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLANS = ['free', 'gym', 'gymplus', 'camp', 'master']
NAMES = {'free': 'Free', 'gym': 'Gym', 'gymplus': 'Gym Plus', 'camp': 'Camp', 'master': 'Master'}
REGULAR = {'gym': 2290, 'gymplus': 4990, 'camp': 5990, 'master': 11990}
LAUNCH = {'free': 0, 'gym': 1490, 'gymplus': 3290, 'camp': 3990, 'master': 7990}
TOP = 'camp'
# the English page also shows dollars and pounds (the same prices are in Stripe, tools in supabase/functions/mf-billing)
USD = {'regular': {'gym': 69, 'gymplus': 149, 'camp': 179, 'master': 359}, 'launch': {'gym': 45, 'gymplus': 99, 'camp': 119, 'master': 239}}
GBP = {'regular': {'gym': 55, 'gymplus': 119, 'camp': 145, 'master': 289}, 'launch': {'gym': 35, 'gymplus': 79, 'camp': 95, 'master': 189}}
SITE = {'thb': '15,000 baht', 'usd': '$450', 'gbp': '£350'}
EXTRA = {'thb': '50 baht', 'usd': '$1.50', 'gbp': '£1.20'}

T = {
 'en': dict(h='Prices', lede='One app for your whole business: members, selling, your team, coaching, marketing, rooms and your website. Prices in US dollars, British pounds or Thai baht. Paid plans are up and running within 4 hours of signing up (9am to 6pm Thai time); when many gyms join at once, there may be a short delay.',
   monthly='Monthly', yearly='Yearly: 12 months for the price of 10', promo='Launch offer: your first 2 months at 50% off', yearpromo='Pay a year upfront: 12 months for the price of 10, and we copy your current website into Muay Friend free (worth {SITE})',
   per='a month', peryear='a year', permonth_y='a month, paid yearly', popular='Most popular', start='Start free', get='Get started',
   pick='Which plan is right for you?', compare='Everything each plan includes', compare_open='See the full list',
   extra='Every paid plan can add members at {EXTRA} a month each, and you always pay the best price: when the next plan costs less than the extras, your bill moves to it by itself. AI tools (Ask AI, reading receipts, writing posts) are an add-on on every plan and included in Master.',
   feature='Feature', yes='Included', no='Not included'),
 'th': dict(h='ราคา', lede='แอปเดียวสำหรับทั้งธุรกิจ: สมาชิก งานขาย ทีมงาน การโค้ช การตลาด ห้องพัก และเว็บไซต์ของคุณ ราคาเป็นเงินบาท แพ็กเกจแบบชำระเงินพร้อมใช้ภายใน 4 ชั่วโมงหลังสมัคร (9.00 ถึง 18.00 น. เวลาไทย) ช่วงที่มียิมสมัครพร้อมกันจำนวนมาก อาจช้ากว่านี้เล็กน้อย',
   monthly='รายเดือน', yearly='รายปี: จ่าย 10 เดือน ใช้ 12 เดือน', promo='โปรเปิดตัว: ลด 50% สองเดือนแรก', yearpromo='จ่ายรายปีล่วงหน้า: จ่าย 10 เดือน ใช้ 12 เดือน และเราย้ายเว็บไซต์ปัจจุบันของคุณเข้า Muay Friend ฟรี (มูลค่า 15,000 บาท)',
   per='ต่อเดือน', peryear='ต่อปี', permonth_y='ต่อเดือน เมื่อจ่ายรายปี', popular='ยอดนิยม', start='เริ่มใช้ฟรี', get='เริ่มต้นใช้งาน',
   pick='แพ็กเกจไหนเหมาะกับคุณ?', compare='ทุกอย่างที่แต่ละแพ็กเกจมี', compare_open='ดูรายการทั้งหมด',
   extra='ทุกแพ็กเกจแบบชำระเงินเพิ่มสมาชิกได้คนละ 50 บาทต่อเดือน และคุณจ่ายราคาที่คุ้มที่สุดเสมอ: เมื่อแพ็กเกจถัดไปถูกกว่าค่าสมาชิกเพิ่ม บิลจะย้ายไปแพ็กเกจนั้นเอง เครื่องมือ AI (Ask AI อ่านใบเสร็จ เขียนโพสต์) เป็นส่วนเสริมได้ทุกแพ็กเกจ และรวมอยู่ใน Master',
   feature='ฟีเจอร์', yes='มี', no='ไม่มี'),
}

LIMITS = {'en': {'free': '15 members, 2 staff', 'gym': '30 members, 6 staff', 'gymplus': '100 members, 10 staff', 'camp': '150 members, 15 staff', 'master': '150 members, unlimited staff'},
          'th': {'free': 'สมาชิก 15 คน พนักงาน 2 คน', 'gym': 'สมาชิก 30 คน พนักงาน 6 คน', 'gymplus': 'สมาชิก 100 คน พนักงาน 10 คน', 'camp': 'สมาชิก 150 คน พนักงาน 15 คน', 'master': 'สมาชิก 150 คน พนักงานไม่จำกัด'}}
FOR = {'en': {'free': 'For a coach or a small gym starting out', 'gym': 'For a small gym that sells at the counter', 'gymplus': 'For a growing gym', 'camp': 'For a busy gym or camp', 'master': 'Everything, for camps with rooms'},
       'th': {'free': 'สำหรับโค้ชหรือยิมเล็กที่เพิ่งเริ่ม', 'gym': 'สำหรับยิมเล็กที่ขายหน้าเคาน์เตอร์', 'gymplus': 'สำหรับยิมที่กำลังโต', 'camp': 'สำหรับยิมหรือแคมป์ที่มีลูกค้าเยอะ', 'master': 'ครบทุกอย่าง สำหรับแคมป์ที่มีห้องพัก'}}
HIGHLIGHTS = {
 'en': {'free': ['Member app with QR check-in', 'Packages, memberships and class passes', 'Timetable, privates and appointments', 'Cash and PromptPay QR', 'Set it up yourself'],
        'gym': ['Everything in Free', 'Card payments in the app', 'Shop and cafe till with stock', 'Staff hours, commission, accounts and receipts', 'Messages with members', 'Website: 1 page with timetable, prices and courses to buy', 'Your own logo and colours', 'We set it up for you'],
        'gymplus': ['Everything in Gym', '100 members and 10 staff', 'Website: 1 page', 'We set it up for you'],
        'camp': ['Everything in Gym Plus', 'Online coaching, courses and technique videos', 'Cafe menu and food orders', 'Newsletters and social media posting', 'Partners and affiliates', 'Fighters, jobs, maintenance and investor view', 'Website: 4 pages', 'We set it up for you'],
        'master': ['Everything in Camp', 'Rooms, stays, room bills and housekeeping', 'Online room booking, Booking.com, Agoda and Airbnb calendars', 'Meal plans and welcome emails', 'Website: 8 pages, page, landing page and blog builder', 'AI tools included', 'Unlimited staff, priority support']},
 'th': {'free': ['แอปสมาชิกพร้อมเช็คอินด้วย QR', 'แพ็กเกจ สมาชิกภาพ และบัตรคลาส', 'ตารางคลาส คลาสส่วนตัว และการนัดหมาย', 'เงินสดและ QR พร้อมเพย์', 'ตั้งค่าด้วยตัวเอง'],
        'gym': ['ทุกอย่างใน Free', 'รับชำระด้วยบัตรในแอป', 'ระบบขายหน้าร้านและคาเฟ่ พร้อมสต็อก', 'เวลาทำงาน ค่าคอมมิชชั่น บัญชี และใบเสร็จ', 'แชทกับสมาชิก', 'เว็บไซต์ 1 หน้า: ตารางคลาส ราคา และคอร์สให้ซื้อ', 'โลโก้และสีของคุณเอง', 'เราตั้งค่าให้'],
        'gymplus': ['ทุกอย่างใน Gym', 'สมาชิก 100 คน พนักงาน 10 คน', 'เว็บไซต์ 1 หน้า', 'เราตั้งค่าให้'],
        'camp': ['ทุกอย่างใน Gym Plus', 'โค้ชออนไลน์ คอร์ส และวิดีโอเทคนิค', 'เมนูคาเฟ่และสั่งอาหาร', 'จดหมายข่าวและโพสต์โซเชียลมีเดีย', 'พาร์ทเนอร์และแอฟฟิลิเอต', 'นักชก งานซ่อมบำรุง และมุมมองนักลงทุน', 'เว็บไซต์ 4 หน้า', 'เราตั้งค่าให้'],
        'master': ['ทุกอย่างใน Camp', 'ห้องพัก การเข้าพัก บิลห้อง และแม่บ้าน', 'จองห้องออนไลน์ และปฏิทิน Booking.com, Agoda, Airbnb', 'แผนอาหารและอีเมลต้อนรับ', 'เว็บไซต์ 8 หน้า พร้อมตัวสร้างหน้าเว็บ แลนดิ้งเพจ และบล็อก', 'รวมเครื่องมือ AI', 'พนักงานไม่จำกัด ซัพพอร์ตก่อนใคร']},
}
PICKS = {
 'en': [('Starting out, or a coach on your own', 'free'), ('A small gym selling at the counter', 'gym'), ('A busy gym or camp with coaching and a cafe', 'camp'), ('A camp with rooms, or you want everything', 'master')],
 'th': [('เพิ่งเริ่ม หรือเป็นโค้ชคนเดียว', 'free'), ('ยิมเล็กที่ขายหน้าเคาน์เตอร์', 'gym'), ('ยิมหรือแคมป์ที่มีโค้ชและคาเฟ่', 'camp'), ('แคมป์ที่มีห้องพัก หรืออยากได้ครบทุกอย่าง', 'master')],
}

# the full list: (English, Thai, [free, gym, gymplus, camp, master]); 1 = included, 0 = not, text = shown as is (English | Thai)
A = [1, 1, 1, 1, 1]; G = [0, 1, 1, 1, 1]; C = [0, 0, 0, 1, 1]; M = [0, 0, 0, 0, 1]
ROWS = [
 ('Members and team', 'สมาชิกและทีมงาน', None),
 ('Active members', 'สมาชิกที่ใช้งานอยู่', ['15', '30', '100', '150', '150']),
 ('Staff logins', 'บัญชีพนักงาน', ['2', '6', '10', '15', 'Unlimited|ไม่จำกัด']),
 ('Extra members at {EXTRA} each, always the best price', 'เพิ่มสมาชิกคนละ 50 บาท ได้ราคาคุ้มที่สุดเสมอ', G),
 ('Roles and permissions for owner, admin, front desk and coaches', 'สิทธิ์ตามตำแหน่ง: เจ้าของ แอดมิน หน้าเคาน์เตอร์ และครู', A),
 ('Running the gym', 'บริหารยิม', None),
 ('Member app with your gym name and QR check-in', 'แอปสมาชิกชื่อยิมของคุณ เช็คอินด้วย QR', A),
 ('Customers, packages, memberships and class passes', 'ลูกค้า แพ็กเกจ สมาชิกภาพ และบัตรคลาส', A),
 ('Class timetable and class check-ins', 'ตารางคลาสและเช็คอินคลาส', A),
 ('Privates and appointments, online booking, any free coach or pick a coach', 'คลาสส่วนตัวและนัดหมาย จองออนไลน์ เลือกครูหรือครูที่ว่าง', A),
 ('Coach view for each coach', 'หน้าจอของครูแต่ละคน', A),
 ('Pay first or pay prompts at check-in', 'ให้จ่ายก่อน หรือเตือนให้จ่ายตอนเช็คอิน', A),
 ('Thai language for staff and members', 'ภาษาไทยสำหรับพนักงานและสมาชิก', A),
 ('Nightly backups', 'สำรองข้อมูลทุกคืน', A),
 ('Package upgrades, free and promo packages', 'อัปเกรดแพ็กเกจ แพ็กเกจฟรีและโปรโมชัน', G),
 ('Customer view: see the app as a member sees it', 'ดูแอปแบบที่สมาชิกเห็น', G),
 ('Myanmar language for staff', 'ภาษาพม่าสำหรับพนักงาน', C),
 ('Selling and payments', 'งานขายและการชำระเงิน', None),
 ('Cash and PromptPay QR straight to your bank, no fees', 'เงินสดและ QR พร้อมเพย์เข้าบัญชีโดยตรง ไม่มีค่าธรรมเนียม', A),
 ('Receipts by email', 'ส่งใบเสร็จทางอีเมล', A),
 ('Card payments in the app and by link (Stripe)', 'รับชำระด้วยบัตรในแอปและผ่านลิงก์ (Stripe)', G),
 ('Shop and till, stock, sizes and colours, extras', 'ขายหน้าร้าน สต็อก ไซซ์และสี ตัวเลือกเสริม', G),
 ('Cafe menu, food orders from the app, kitchen screen', 'เมนูคาเฟ่ สั่งอาหารผ่านแอป จอห้องครัว', C),
 ('Bookings from GetYourGuide, Viator and Klook read in by themselves', 'ดึงการจองจาก GetYourGuide, Viator และ Klook เข้ามาเอง', C),
 ('Team and money', 'ทีมงานและการเงิน', None),
 ('Staff hours, clock in and out', 'เวลาทำงาน ลงเวลาเข้าออก', G),
 ('Coach commission and coach own private rates', 'ค่าคอมมิชชั่นครูและราคาคลาสส่วนตัวของครู', G),
 ('Expense receipts, accounts, monthly bills and invoices', 'ใบเสร็จค่าใช้จ่าย บัญชี บิลรายเดือน และใบแจ้งหนี้', G),
 ('Messages and group chats with members', 'แชทและกลุ่มแชทกับสมาชิก', G),
 ('Group privates with several coaches or people', 'คลาสส่วนตัวแบบกลุ่ม หลายครูหรือหลายคน', C),
 ('Jobs, maintenance and work log', 'งาน ซ่อมบำรุง และบันทึกงาน', C),
 ('Investor view with totals only', 'มุมมองนักลงทุน แสดงเฉพาะยอดรวม', C),
 ('Coaching and learning', 'การโค้ชและการเรียนรู้', None),
 ('Online coaching: programmes, habits, food diary, weight, check-ins', 'โค้ชออนไลน์: โปรแกรม นิสัย บันทึกอาหาร น้ำหนัก เช็คอิน', C),
 ('Video courses and technique library', 'คอร์สวิดีโอและคลังเทคนิค', C),
 ('Fighters and fight records', 'นักชกและสถิติการชก', C),
 ('Marketing', 'การตลาด', None),
 ('Website chat into the app', 'แชทจากเว็บไซต์เข้าแอป', G),
 ('Contacts, lists and newsletters', 'รายชื่อติดต่อ ลิสต์ และจดหมายข่าว', C),
 ('Posts, reels and stories to Facebook, Instagram, TikTok and YouTube', 'โพสต์ รีล และสตอรี่ ไป Facebook, Instagram, TikTok และ YouTube', C),
 ('Partner and affiliate programme with tracked links', 'โปรแกรมพาร์ทเนอร์และแอฟฟิลิเอต พร้อมลิงก์ติดตาม', C),
 ('Your website', 'เว็บไซต์ของคุณ', None),
 ('Integrated website, edited from your phone', 'เว็บไซต์ในตัว แก้ไขได้จากมือถือ', ['0', '1 page|1 หน้า', '1 page|1 หน้า', '4 pages|4 หน้า', '8 pages|8 หน้า']),
 ('Timetable, prices and courses to buy on your website', 'ตารางคลาส ราคา และคอร์สให้ซื้อบนเว็บไซต์', G),
 ('Website numbers: visits and bookings', 'สถิติเว็บไซต์: ผู้เข้าชมและการจอง', C),
 ('Team on your website from Staff, with videos', 'ทีมงานบนเว็บไซต์จากหน้าพนักงาน พร้อมวิดีโอ', C),
 ('Page, landing page and blog builder', 'ตัวสร้างหน้าเว็บ แลนดิ้งเพจ และบล็อก', M),
 ('Rooms', 'ห้องพัก', None),
 ('Rooms, stays, room bills and housekeeping', 'ห้องพัก การเข้าพัก บิลห้อง และแม่บ้าน', M),
 ('Online room booking with extras', 'จองห้องออนไลน์พร้อมบริการเสริม', M),
 ('Booking.com, Agoda and Airbnb calendars kept in step', 'ปฏิทิน Booking.com, Agoda และ Airbnb ตรงกันเสมอ', M),
 ('Meal plans and welcome emails before arrival', 'แผนอาหารและอีเมลต้อนรับก่อนมาถึง', M),
 ('AI', 'AI', None),
 ('Ask AI, reading receipts, writing posts, clean up', 'Ask AI อ่านใบเสร็จ เขียนโพสต์ จัดระเบียบข้อมูล', ['Add-on|ส่วนเสริม'] * 4 + ['1']),
 ('Your way', 'ปรับให้เป็นแบบของคุณ', None),
 ('Your logo, colours and app name', 'โลโก้ สี และชื่อแอปของคุณ', ['Small Muay Friend logo|มีโลโก้ Muay Friend เล็กๆ', '1', '1', '1', '1']),
 ('Turn every feature on or off', 'เปิดหรือปิดได้ทุกฟีเจอร์', A),
 ('Your own private database', 'ฐานข้อมูลส่วนตัวของคุณเอง', ['Shared, kept separate|ใช้ร่วม แยกข้อมูลกัน', '1', '1', '1', '1']),
 ('Set up for you, members and packages brought in', 'ตั้งค่าให้ และย้ายสมาชิกกับแพ็กเกจเข้ามาให้', G),
 ('Support', 'ซัพพอร์ต', ['Email|อีเมล', 'WhatsApp', 'WhatsApp', 'WhatsApp', 'Priority WhatsApp|WhatsApp ก่อนใคร']),
]

def money(n): return f'{n:,}'

def fmt(cur, n):
    if cur == 'thb': return money(n)
    sym = '$' if cur == 'usd' else '£'
    return sym + (f'{n:,.2f}' if n != int(n) else f'{int(n):,}')

def amt(lang, thb, usd, gbp, tail=''):
    """A price: baht only on the Thai page; on the English page, all three, switched by the currency buttons."""
    if lang == 'th': return money(thb) + tail
    return (f'<span class="cur" data-thb="{money(thb)}{tail}" data-usd="{fmt("usd", usd)}{tail}" data-gbp="{fmt("gbp", gbp)}{tail}">'
            f'{fmt("usd", usd)}{tail}</span>')

def words(lang, d):
    if lang == 'th': return d['thb']
    return f'<span class="cur" data-thb="{d["thb"]}" data-usd="{d["usd"]}" data-gbp="{d["gbp"]}">{d["usd"]}</span>'

def cell(v, lang):
    if v in (1, '1'): return '<td class="y"><span class="ok" aria-label="%s"></span></td>' % T[lang]['yes']
    if v in (0, '0'): return '<td class="n"><span class="no" aria-label="%s"></span></td>' % T[lang]['no']
    parts = str(v).split('|'); return '<td>%s</td>' % (parts[1] if lang == 'th' and len(parts) > 1 else parts[0])

def section(lang):
    t = T[lang]; o = []
    o.append('  <section class="block" id="pricing">\n    <div class="wrap">')
    o.append(f'      <div class="head"><h2>{t["h"]}</h2></div>\n      <p class="lede">{t["lede"]}</p>')
    cur = '' if lang == 'th' else ('<div class="billing curs" role="group" aria-label="Currency"><button type="button" class="on" data-cur="usd">US $</button>'
                                   '<button type="button" data-cur="gbp">UK £</button><button type="button" data-cur="thb">Thai baht</button></div>')
    o.append(f'      <div class="billing" role="group"><button type="button" class="on" data-bill="m">{t["monthly"]}</button><button type="button" data-bill="y">{t["yearly"]}</button></div>{cur}')
    o.append(f'      <p class="promo" data-show="m">{t["promo"]}</p><p class="promo" data-show="y" hidden>{t["yearpromo"].replace("{SITE}", words(lang, SITE))}</p>')
    o.append(f'      <h3 class="pickh">{t["pick"]}</h3>\n      <div class="picks">' + ''.join(f'<a href="#plan-{k}"><span>{q}</span><b>{NAMES[k]}</b></a>' for q, k in PICKS[lang]) + '</div>')
    o.append('      <div class="plans">')
    for k in PLANS:
        top = k == TOP; free = k == 'free'
        o.append(f'        <div class="plan{" top" if top else ""}" id="plan-{k}">')
        if top: o.append(f'          <p class="badge">{t["popular"]}</p>')
        o.append(f'          <h3>{NAMES[k]}</h3>\n          <p class="for">{FOR[lang][k]}</p>')
        if free:
            o.append(f'          <p class="was"></p>\n          <p class="now">0 <small>{t["per"]}</small></p>')
        else:
            y = LAUNCH[k] * 10; uy = USD['launch'][k] * 10; gy = GBP['launch'][k] * 10
            o.append(f'          <p class="was" data-show="m">{amt(lang, REGULAR[k], USD["regular"][k], GBP["regular"][k])}</p>'
                     f'<p class="was" data-show="y" hidden>{amt(lang, REGULAR[k] * 12, USD["regular"][k] * 12, GBP["regular"][k] * 12)} {t["peryear"]}</p>')
            o.append(f'          <p class="now" data-show="m">{amt(lang, LAUNCH[k], USD["launch"][k], GBP["launch"][k])} <small>{t["per"]}</small></p>'
                     f'<p class="now" data-show="y" hidden>{amt(lang, y, uy, gy)} <small>{t["peryear"]}</small></p>'
                     f'<p class="sub" data-show="y" hidden>{amt(lang, round(y / 12), round(uy / 12), round(gy / 12))} {t["permonth_y"]}</p>')
        o.append(f'          <p class="lim">{LIMITS[lang][k]}</p>')
        o.append('          <ul>' + ''.join(f'<li>{x}</li>' for x in HIGHLIGHTS[lang][k]) + '</ul>')
        cls = '' if (top or free) else ' ghost'
        href, cta = ('#free', t['start']) if free else ('#contact', t['get'])
        dp = '' if free else f' data-plan="{NAMES[k]}"'
        o.append(f'          <a class="btn{cls}" href="{href}"{dp}>{cta}</a>\n        </div>')
    o.append('      </div>')
    o.append(f'      <p class="addons">{t["extra"].replace("{EXTRA}", words(lang, EXTRA))}</p>')
    o.append(f'      <details class="compare" id="compare"><summary>{t["compare"]}: {t["compare_open"]}</summary><div class="ctable"><table>')
    o.append('<thead><tr><th scope="col">%s</th>%s</tr></thead><tbody>' % (t['feature'], ''.join(f'<th scope="col">{NAMES[k]}</th>' for k in PLANS)))
    for en, th, v in ROWS:
        name = th if lang == 'th' else en.replace('{EXTRA}', words(lang, EXTRA))
        if v is None: o.append(f'<tr class="grp"><th colspan="6" scope="colgroup">{name}</th></tr>')
        else: o.append(f'<tr><th scope="row">{name}</th>' + ''.join(cell(x, lang) for x in v) + '</tr>')
    o.append('</tbody></table></div></details>')
    return '\n'.join(o) + '\n'

CSS = """/* pricing v2 */
#pricing [hidden]{display:none!important}
.billing{display:inline-flex;margin-top:22px;border:1.5px solid var(--ink);border-radius:999px;padding:4px;gap:4px;flex-wrap:wrap}
.billing button{font:600 15px var(--body);border:0;background:transparent;color:var(--ink);padding:10px 18px;border-radius:999px;cursor:pointer}
.billing button.on{background:var(--ink);color:#fff}
.billing.curs{margin-left:10px}
@media (max-width:640px){.billing.curs{margin-left:0;margin-top:10px}}
.pickh{font-size:28px;margin-top:34px}
.picks{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-top:14px}
.picks a{display:flex;flex-direction:column;gap:6px;padding:16px 18px;border-radius:16px;background:#fff;border:1.5px solid var(--line);color:var(--ink);text-decoration:none}
.picks a:hover{border-color:var(--blue)}
.picks span{color:var(--ink2);font-size:15px}
.picks b{font:800 24px var(--display);color:var(--blue)}
.plan{position:relative}
.plan .badge{position:absolute;top:-13px;left:22px;margin:0;padding:4px 12px;border-radius:999px;background:var(--blue);color:#fff;font-size:13px;font-weight:600}
.plan .for{color:var(--muted);font-size:15px;min-height:42px;margin:0}
.plan .sub{color:var(--muted);font-size:14px;margin:0}
.compare{margin-top:28px;background:#fff;border:1.5px solid var(--line);border-radius:20px;padding:0 20px}
.compare summary{cursor:pointer;padding:20px 0;font-weight:700;font-size:19px;color:var(--blue)}
.ctable{overflow-x:auto;padding-bottom:20px}
.compare table{border-collapse:collapse;width:100%;min-width:720px;font-size:15px}
.compare th,.compare td{padding:10px 8px;border-bottom:1px solid var(--line);text-align:center}
.compare thead th{position:sticky;top:0;background:#fff;font:800 20px var(--display)}
.compare th[scope=row]{text-align:left;font-weight:500;color:var(--ink2);width:40%}
.compare thead th:first-child{text-align:left}
.compare tr.grp th{text-align:left;background:var(--paper);font-weight:700;color:var(--ink);padding-top:14px}
.compare .ok{display:inline-block;width:14px;height:8px;border-left:3px solid var(--blue);border-bottom:3px solid var(--blue);transform:rotate(-45deg)}
.compare .no{display:inline-block;width:12px;height:2px;background:#C3C7BF}
@media (max-width:900px){.picks{grid-template-columns:1fr 1fr}}
@media (max-width:520px){.picks{grid-template-columns:1fr}}
"""
JS = """<script>
(function(){
  var bs=document.querySelectorAll('[data-bill]');
  function set(m){ bs.forEach(function(b){ b.classList.toggle('on',b.getAttribute('data-bill')===m); });
    document.querySelectorAll('#pricing [data-show]').forEach(function(e){ e.hidden=e.getAttribute('data-show')!==m; }); }
  bs.forEach(function(b){ b.addEventListener('click',function(){ set(b.getAttribute('data-bill')); }); });
  /* currency: the visitor's own (Thailand baht, UK pounds, else dollars), or what they picked */
  var cs=document.querySelectorAll('[data-cur]'); if(!cs.length) return;
  function cur(c){ cs.forEach(function(b){ b.classList.toggle('on',b.getAttribute('data-cur')===c); });
    document.querySelectorAll('.cur').forEach(function(e){ var v=e.getAttribute('data-'+c); if(v) e.textContent=v; });
    try{ localStorage.setItem('mf_cur',c); }catch(e){} }
  var c=null; try{ c=localStorage.getItem('mf_cur'); }catch(e){}
  if(!c){ var tz=''; try{ tz=Intl.DateTimeFormat().resolvedOptions().timeZone||''; }catch(e){}
    var l=(navigator.language||'').toLowerCase();
    c=tz==='Asia/Bangkok'||/^th/.test(l)?'thb':(tz==='Europe/London'||l==='en-gb')?'gbp':'usd'; }
  cs.forEach(function(b){ b.addEventListener('click',function(){ cur(b.getAttribute('data-cur')); }); });
  cur(c);
})();
</script>
"""

def apply(path, lang):
    s = open(path, encoding='utf-8').read()
    a = s.index('  <section class="block" id="pricing">')
    w = s.index('      <div class="webpitch">', a)
    s = s[:a] + section(lang) + s[w:]
    if lang == 'en':
        if '/* pricing v2 */' in s:
            s = re.sub(r'/\* pricing v2 \*/.*?(?=/\* start free \*/)', CSS, s, flags=re.S)
        else:
            s = s.replace('/* start free */', CSS + '/* start free */', 1)
    s = re.sub(r"<script>\n\(function\(\)\{\n  var bs=document.querySelectorAll\('\[data-bill\]'\);.*?</script>\n", '', s, flags=re.S)
    s = s.replace('</body>', JS + '</body>', 1)
    s = s.replace('Camp + Stay', 'Master')
    open(path, 'w', encoding='utf-8').write(s)

apply(os.path.join(ROOT, 'muayfriend', 'index.html'), 'en')
apply(os.path.join(ROOT, 'tools', 'mf_th_body.html'), 'th')
print('Prices section built')
