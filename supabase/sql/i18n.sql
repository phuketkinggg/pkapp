-- App languages: Thai and Myanmar next to English. The words are in i18n-th.js and i18n-my.js;
-- a manager's fixes (Settings, Languages) are kept here and read by everyone, signed in or not (the sign in screen is translated too).
insert into public.app_settings (key, value) values ('i18n_fix', '{}') on conflict (key) do nothing;
create or replace function public.i18n_fixes() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'i18n_fix'), '{}'::jsonb)
$$;
revoke all on function public.i18n_fixes() from public;
grant execute on function public.i18n_fixes() to anon, authenticated;
