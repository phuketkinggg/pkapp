-- App languages filled by AI and kept in the database (Russian first: feature lang_ru).
-- The function i18n-auto translates the app's own words (i18n/strings.json in the repo) into a language and keeps them here.
-- The app loads them with i18n_pack(lang) when someone picks that language. Fixes made in Settings, Languages still win.
create table if not exists public.i18n_auto (
  lang text not null,
  en text not null,
  tr text not null,
  at timestamptz not null default now(),
  primary key (lang, en)
);
alter table public.i18n_auto enable row level security;
revoke all on public.i18n_auto from public, anon, authenticated;

-- the words for one language: {d: {english: translation}, p: {pieces that can sit inside longer texts}}
create or replace function public.i18n_pack(p_lang text) returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when p_lang ~ '^[a-z]{2}$' and private.feature('lang_' || p_lang, false) then jsonb_build_object(
    'd', coalesce((select jsonb_object_agg(btrim(en), tr) from public.i18n_auto where lang = p_lang and btrim(tr) <> '' and btrim(en) <> ''), '{}'::jsonb),
    'p', coalesce((select jsonb_object_agg(btrim(en), 1) from public.i18n_auto where lang = p_lang and btrim(tr) <> '' and btrim(en) <> ''
                   and (en <> btrim(en) or btrim(en) ~ '^[,.:;(]' or btrim(en) ~ '[,:(]$')), '{}'::jsonb))
  else '{}'::jsonb end
$f$;
revoke all on function public.i18n_pack(text) from public;
grant execute on function public.i18n_pack(text) to anon, authenticated;

-- how far a language is (for the team)
create or replace function public.i18n_count(p_lang text) returns integer language sql stable security definer set search_path to '' as $f$
  select count(*)::int from public.i18n_auto where lang = p_lang
$f$;
revoke all on function public.i18n_count(text) from public, anon;
grant execute on function public.i18n_count(text) to authenticated;

notify pgrst, 'reload schema';
