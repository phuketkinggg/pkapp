delete from mf.template where name like 'area_map:%';
insert into mf.template (ord, phase, kind, name, sql) values (405401, 4, 'patch', 'area_map:405401', $TPL$create or replace function __P__.area_map_url() returns text language sql stable security definer set search_path = '' as $f$
  select case when __Q__.feature('area_map', false) then
    (select v from (select btrim(value) v from __P__.app_settings where key = 'area_map_url') x where v ~ '^https://[^\s<>"]+$') end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199501, 11, 'patch', 'area_map:1199501', $TPL$revoke all on function __P__.area_map_url() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199502, 11, 'patch', 'area_map:1199502', $TPL$grant execute on function __P__.area_map_url() to anon, authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'area_map:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
