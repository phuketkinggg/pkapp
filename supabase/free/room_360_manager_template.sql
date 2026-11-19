delete from mf.template where name like 'room_360_manager:%';
insert into mf.template (ord, phase, kind, name, sql) values (403751, 4, 'patch', 'room_360_manager:403751', $TPL$create or replace function __P__.room_360() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when __Q__.feature('room_360', true) or coalesce(__Q__.staff_role(), '') = 'manager'
    then coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'room_360'), '{}'::jsonb) else '{}'::jsonb end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197751, 11, 'patch', 'room_360_manager:1197751', $TPL$revoke all on function __P__.room_360() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197752, 11, 'patch', 'room_360_manager:1197752', $TPL$grant execute on function __P__.room_360() to anon, authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'room_360_manager:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
