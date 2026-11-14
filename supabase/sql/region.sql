-- Country, currency and time zone (Settings, General, Country, currency and time zone): the business's own time zone decides
-- "today" (check ins, packages, bookings, reports) and its currency is shown on prices. Thailand (Asia/Bangkok, THB) unless set.
-- Every database function that used Thailand time now uses the business's time zone, and notices show its currency.

create or replace function private.tz() returns text language sql stable security definer set search_path to '' as $f$
  select coalesce((select case when value ~ '^\s*\{' then nullif(value::jsonb->>'tz', '') end from public.app_settings where key = 'region'), 'Asia/Bangkok')
$f$;
create or replace function private.cur() returns text language sql stable security definer set search_path to '' as $f$
  select coalesce((select case when value ~ '^\s*\{' then nullif(value::jsonb->>'cur', '') end from public.app_settings where key = 'region'), 'THB')
$f$;

-- anyone (the member app and the website too): the time zone and currency to show
create or replace function public.app_region() returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('tz', private.tz(), 'cur', private.cur(),
    'country', coalesce((select case when value ~ '^\s*\{' then value::jsonb->>'country' end from public.app_settings where key = 'region'), 'TH'))
$f$;
grant execute on function public.app_region() to anon, authenticated;

create or replace function public.app_region_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare tz text := btrim(coalesce(p->>'tz', '')); cu text := upper(btrim(coalesce(p->>'cur', '')));
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  if not exists (select 1 from pg_timezone_names where name = tz) then raise exception 'Choose a time zone from the list.'; end if;
  if cu !~ '^[A-Z]{3}$' then raise exception 'Choose a currency from the list.'; end if;
  insert into public.app_settings (key, value) values ('region', jsonb_build_object('tz', tz, 'cur', cu, 'country', left(upper(coalesce(p->>'country', '')), 2))::text)
    on conflict (key) do update set value = excluded.value;
  return public.app_region();
end $f$;
revoke all on function public.app_region_save(jsonb) from public, anon;
grant execute on function public.app_region_save(jsonb) to authenticated;

-- every function that used Thailand time or wrote THB: the business's own time zone and currency
do $p$
declare r record; d text; n text;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname in ('public','private') and p.prokind = 'f' and p.proname not in ('tz','cur','app_region','app_region_save')
             and (p.prosrc like '%''Asia/Bangkok''%' or p.prosrc like '%'' THB''%') loop
    d := pg_get_functiondef(r.oid);
    n := regexp_replace(d, '([^''])''Asia/Bangkok''([^''])', '\1private.tz()\2', 'g');
    n := regexp_replace(n, '([^''])'' THB''([^''])', '\1('' '' || private.cur())\2', 'g');
    if n <> d then
      begin execute n;
      exception when others then raise notice 'region: % kept as it was (%)', r.proname, sqlerrm; end;
    end if;
  end loop;
end $p$;

notify pgrst, 'reload schema';
