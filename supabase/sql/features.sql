-- Feature switches: each business turns parts of the app on or off (Settings, Features).
-- app_settings 'features' = {"key": true|false} holds only what the owner changed; defaults live in the app (FEATURES in index.html).
insert into public.app_settings(key, value) values ('features', '{}') on conflict (key) do nothing;

create or replace function private.features() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'features'), '{}'::jsonb)
$$;
-- server side check: private.feature('key', default)
create or replace function private.feature(p_key text, p_default boolean default true) returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce((private.features()->>p_key)::boolean, p_default)
$$;
revoke all on function private.features() from public, anon, authenticated;
revoke all on function private.feature(text, boolean) from public, anon;
grant execute on function private.feature(text, boolean) to authenticated;

-- everyone reads them (the customer app hides tabs too), only true and false come out
create or replace function public.app_features() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) from jsonb_each(private.features()) e
  where e.key ~ '^[a-z0-9_]{1,40}$' and jsonb_typeof(e.value) = 'boolean'
$$;
revoke all on function public.app_features() from public;
grant execute on function public.app_features() to anon, authenticated;

-- the owner (or an admin with settings) switches one
create or replace function public.feature_set(p_key text, p_on boolean) returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(), '') <> 'manager' or not private.can('settings') then raise exception 'Only the owner or an admin with settings can switch features.'; end if;
  if p_key !~ '^[a-z0-9_]{1,40}$' then raise exception 'Unknown feature.'; end if;
  update public.app_settings set value = (private.features() || jsonb_build_object(p_key, p_on))::text, updated_at = now() where key = 'features';
  return public.app_features();
end $$;
revoke all on function public.feature_set(text, boolean) from public, anon;
grant execute on function public.feature_set(text, boolean) to authenticated;

-- receipts: with "Everyone adds receipts" off, only managers and admins add them
do $$ declare s text;
begin
  s := pg_get_functiondef('public.receipt_add(jsonb)'::regprocedure);
  if s not like '%receipts_all%' then
    s := replace(s, $a$  if not private.any_staff() then raise exception 'Not allowed.'; end if;$a$,
      $a$  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  if not private.feature('receipts_all', true) and coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only managers add receipts here.'; end if;$a$);
    if s not like '%receipts_all%' then raise exception 'receipt_add patch did not apply'; end if;
    execute s;
  end if;
end $$;

-- online booking: the coach video only while Profile videos is on
do $$ declare s text;
begin
  s := pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure);
  if s like '%video_url%' and s not like '%profile_video%' then
    s := replace(s, $a$'video', (select x.video_url from public.staff x where x.id = s.id)$a$, $a$'video', case when private.feature('profile_video', true) then (select x.video_url from public.staff x where x.id = s.id) end$a$);
    if s not like '%profile_video%' then raise exception 'private_book_slots patch did not apply'; end if;
    execute s;
  end if;
end $$;
