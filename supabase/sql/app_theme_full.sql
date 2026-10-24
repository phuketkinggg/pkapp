-- App colours: the highlight (accent) plus an optional background, title colour, menu colour and light or dark.
-- Read by everyone (also before sign in); only a manager can change the 'app_theme' row (app_settings rules).
insert into public.app_settings(key,value) values ('app_theme','{}') on conflict (key) do nothing;
create or replace function public.app_theme() returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
  from jsonb_each(coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key='app_theme'),'{}'::jsonb)) e
  where (e.key in ('accent','bg','title','side') and e.value #>> '{}' ~ '^#[0-9A-Fa-f]{6}$') or (e.key = 'mode' and e.value #>> '{}' in ('light','dark'))
$$;
revoke all on function public.app_theme() from public;
grant execute on function public.app_theme() to anon, authenticated;
