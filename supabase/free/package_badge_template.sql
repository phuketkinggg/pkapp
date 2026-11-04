delete from mf.template where name like 'package_badge:%';
insert into mf.template (ord, phase, kind, name, sql) values (300701, 3, 'patch', 'package_badge:300701', $TPL$alter table __P__.packages add column if not exists badge text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300702, 3, 'patch', 'package_badge:300702', $TPL$alter table __P__.packages add column if not exists was_thb integer;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'package_badge:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
