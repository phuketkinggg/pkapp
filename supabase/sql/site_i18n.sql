-- Website languages (feature web_langs): the website's English texts translated by AI.
-- The edge function site-i18n fills this table from pk/lang/strings.json and serves one language at a time;
-- tools/site_lang_pull.py brings them into the website build (pk/lang/<code>.json). A cron job translates new texts every few hours.
create table if not exists public.site_i18n (
  lang text not null,
  en text not null,
  tr text not null,
  at timestamptz not null default now(),
  primary key (lang, en)
);
alter table public.site_i18n enable row level security;
revoke all on public.site_i18n from public, anon, authenticated;
