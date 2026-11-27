delete from mf.template where name like 'contact_info:%';
insert into mf.template (ord, phase, kind, name, sql) values (406301, 4, 'patch', 'contact_info:406301', $TPL$create or replace function __P__.contact_info() returns jsonb language sql stable security definer set search_path = '' as $f$
  select coalesce((select case when a.value ~ '^\s*\{' then (
      select jsonb_object_agg(k, v) from jsonb_each(a.value::jsonb) x(k, v)
      where k in ('phone','whatsapp','email','line','address','instagram','facebook','youtube','tiktok','extra')) end
    from __P__.app_settings a where a.key = 'contact_info'), '{}'::jsonb)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199991, 11, 'patch', 'contact_info:1199991', $TPL$revoke all on function __P__.contact_info() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199992, 11, 'patch', 'contact_info:1199992', $TPL$grant execute on function __P__.contact_info() to anon, authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'contact_info:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
