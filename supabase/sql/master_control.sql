-- Master control: the app's owner (the company that runs the app, not the business) decides, for each business,
-- which features are fixed on or off (and hidden from the business), which menu items and settings folders are hidden,
-- and what menu items are called (for example "Appointments" instead of "Privates").
-- Kept in private.platform, so a business manager cannot change it. Who the app owners are: private.platform_owners (emails),
-- added by hand per database:  insert into private.platform_owners(email) values ('you@example.com');
create table if not exists private.platform_owners (email text primary key);
create table if not exists private.platform (id int primary key default 1 check (id = 1), cfg jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
insert into private.platform(id) values (1) on conflict (id) do nothing;
revoke all on private.platform_owners from public, anon, authenticated;
revoke all on private.platform from public, anon, authenticated;

create or replace function private.is_platform_owner() returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from private.platform_owners where lower(email) = lower(coalesce(auth.jwt()->>'email', '')) and coalesce(auth.jwt()->>'email','') <> '')
$$;
revoke all on function private.is_platform_owner() from public, anon;
grant execute on function private.is_platform_owner() to authenticated;

-- features the app owner fixed win over the business's own choice, also server side
create or replace function private.features() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'features'), '{}'::jsonb)
    || coalesce((select case when jsonb_typeof(cfg->'lock') = 'object' then cfg->'lock' end from private.platform where id = 1), '{}'::jsonb)
$$;
revoke all on function private.features() from public, anon, authenticated;

-- everyone reads it (menu names show to customers too); owner says if you may change it
create or replace function public.app_platform() returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('cfg', coalesce((select cfg from private.platform where id = 1), '{}'::jsonb), 'owner', private.is_platform_owner())
$$;
revoke all on function public.app_platform() from public;
grant execute on function public.app_platform() to anon, authenticated;

create or replace function public.platform_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
declare lock jsonb := '{}'; hide jsonb := '[]'; hset jsonb := '[]'; names jsonb := '{}'; k text; v jsonb;
begin
  if not private.is_platform_owner() then raise exception 'Only the owner of the app can change Master control.'; end if;
  for k, v in select * from jsonb_each(coalesce(p->'lock','{}')) loop
    if k ~ '^[a-z0-9_]{1,40}$' and jsonb_typeof(v) = 'boolean' then lock := lock || jsonb_build_object(k, v); end if; end loop;
  select coalesce(jsonb_agg(x), '[]') into hide from (select distinct x from jsonb_array_elements_text(coalesce(p->'hide','[]')) x where x ~ '^[a-z0-9_]{1,40}$') s;
  select coalesce(jsonb_agg(x), '[]') into hset from (select distinct x from jsonb_array_elements_text(coalesce(p->'hide_set','[]')) x where x ~ '^[a-z0-9_]{1,40}$') s;
  for k, v in select * from jsonb_each(coalesce(p->'names','{}')) loop
    if k ~ '^[a-z0-9_]{1,40}$' and jsonb_typeof(v) = 'string' and btrim(v#>>'{}') <> '' then names := names || jsonb_build_object(k, left(btrim(v#>>'{}'), 40)); end if; end loop;
  update private.platform set cfg = jsonb_build_object('lock', lock, 'hide', hide, 'hide_set', hset, 'names', names), updated_at = now() where id = 1;
  return public.app_platform();
end $$;
revoke all on function public.platform_save(jsonb) from public, anon;
grant execute on function public.platform_save(jsonb) to authenticated;
