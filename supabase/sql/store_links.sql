-- Links to the business's app in Google Play and the App Store (app_settings key store_links: {"android": "...", "ios": "..."}).
-- Read by the website (Get it on Google Play button) and by the app's install screen, so phones get the store app.
-- Only real store addresses are given out.
create or replace function public.store_links() returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'android', case when v->>'android' ~ '^https://play\.google\.com/store/apps/details\?id=[A-Za-z0-9._]+$' then v->>'android' end,
    'ios', case when v->>'ios' ~ '^https://apps\.apple\.com/[A-Za-z0-9/._?=&-]+$' then v->>'ios' end))
  from (select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'store_links'), '{}'::jsonb) v) x
$$;
revoke all on function public.store_links() from public;
grant execute on function public.store_links() to anon, authenticated;
notify pgrst, 'reload schema';
