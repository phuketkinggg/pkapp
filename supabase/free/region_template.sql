delete from mf.template where name like 'region:%';
insert into mf.template (ord, phase, kind, name, sql) values (403551, 4, 'patch', 'region:403551', $TPL$create or replace function __Q__.tz() returns text language sql stable security definer set search_path to '' as $f$
  select coalesce((select case when value ~ '^\s*\{' then nullif(value::jsonb->>'tz', '') end from __P__.app_settings where key = 'region'), 'Asia/Bangkok')
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403552, 4, 'patch', 'region:403552', $TPL$create or replace function __Q__.cur() returns text language sql stable security definer set search_path to '' as $f$
  select coalesce((select case when value ~ '^\s*\{' then nullif(value::jsonb->>'cur', '') end from __P__.app_settings where key = 'region'), 'THB')
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403553, 4, 'patch', 'region:403553', $TPL$create or replace function __P__.app_region() returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('tz', __Q__.tz(), 'cur', __Q__.cur(),
    'country', coalesce((select case when value ~ '^\s*\{' then value::jsonb->>'country' end from __P__.app_settings where key = 'region'), 'TH'))
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197561, 11, 'patch', 'region:1197561', $TPL$grant execute on function __P__.app_region() to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403554, 4, 'patch', 'region:403554', $TPL$create or replace function __P__.app_region_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare tz text := btrim(coalesce(p->>'tz', '')); cu text := upper(btrim(coalesce(p->>'cur', '')));
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  if not exists (select 1 from pg_timezone_names where name = tz) then raise exception 'Choose a time zone from the list.'; end if;
  if cu !~ '^[A-Z]{3}$' then raise exception 'Choose a currency from the list.'; end if;
  insert into __P__.app_settings (key, value) values ('region', jsonb_build_object('tz', tz, 'cur', cu, 'country', left(upper(coalesce(p->>'country', '')), 2))::text)
    on conflict (key) do update set value = excluded.value;
  return __P__.app_region();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197562, 11, 'patch', 'region:1197562', $TPL$revoke all on function __P__.app_region_save(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197563, 11, 'patch', 'region:1197563', $TPL$grant execute on function __P__.app_region_save(jsonb) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002141, 10, 'patch', 'region:1002141', $TPL$do $p$
declare r record; d text; n text;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname in ('__P__','__Q__') and p.prokind = 'f' and p.proname not in ('tz','cur','app_region','app_region_save')
             and (p.prosrc like '%''Asia/Bangkok''%' or p.prosrc like '%'' THB''%') loop
    d := pg_get_functiondef(r.oid);
    n := regexp_replace(d, '([^''])''Asia/Bangkok''([^''])', '\1__Q__.tz()\2', 'g');
    n := regexp_replace(n, '([^''])'' THB''([^''])', '\1('' '' || __Q__.cur())\2', 'g');
    if n <> d then
      begin execute n;
      exception when others then raise notice 'region: % kept as it was (%)', r.proname, sqlerrm; end;
    end if;
  end loop;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'region:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
