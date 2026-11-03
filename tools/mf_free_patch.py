#!/usr/bin/env python3
"""Turns a supabase/sql/<name>.sql patch into SQL for the shared free database (bnglnfdgptvnmugntiom):
rows added to the gym template (mf.template), then run on every ready gym's schemas. Storage changes run once.
Usage: python3 tools/mf_free_patch.py supabase/sql/coach_docs.sql > out.sql"""
import re, sys
src = open(sys.argv[1]).read(); tag = sys.argv[1].split('/')[-1].replace('.sql', '')
body = '\n'.join(l for l in src.split('\n') if not l.startswith('--'))
stmts, buf, tagq = [], '', None
for l in body.split('\n'):
    if not l.strip() and not buf: continue
    buf += l + '\n'
    if tagq is None:
        m = re.search(r'\bas (\$[a-z]*\$)', buf)
        if m and buf.count(m.group(1)) == 1 and re.search(r'create or replace function', buf): tagq = m.group(1)
    if tagq:
        if buf.count(tagq) >= 2 and l.rstrip().endswith(';'): stmts.append(buf.strip()); buf = ''; tagq = None
    elif l.rstrip().endswith(';'): stmts.append(buf.strip()); buf = ''
def tpl(s): return re.sub(r'\bprivate\.(?=["a-z_])', '__Q__.', re.sub(r'\bpublic\.(?=["a-z_])', '__P__.', s))
base = {3: 300600, 4: 400900, 9: 900300, 10: 1000300, 11: 1103500}; cnt = {}; out = [f"delete from mf.template where name like '{tag}:%';"]; once = []
for s in stmts:
    if s.startswith('notify'): continue
    if 'storage.' in s: once.append(s); continue
    if s.startswith(('create table', 'alter table')): ph = 3
    elif s.startswith('create or replace function'): ph = 4
    elif ' trigger ' in s: ph = 9
    elif s.startswith(('revoke', 'grant')): ph = 11
    else: ph = 10
    cnt[ph] = cnt.get(ph, 0) + 1; o = base[ph] + cnt[ph]
    out.append(f"insert into mf.template (ord, phase, kind, name, sql) values ({o}, {ph}, 'patch', '{tag}:{o}', $TPL${tpl(s)}$TPL$);")
out.append(f"""do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like '{tag}:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;""")
out += once + ["notify pgrst, 'reload schema';"]
print('\n'.join(out))
