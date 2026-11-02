-- Muay Friend free: instant sign-up from the website (edge function mf-signup in the free project).
-- mf.cfg holds the free settings (free_cap: how many free gyms we take), mf.signups logs every try (spam guard).
create table if not exists mf.cfg (key text primary key, value jsonb not null);
insert into mf.cfg (key, value) values ('free_cap', '50'), ('gyms_per_email', '3') on conflict (key) do nothing;
create table if not exists mf.signups (
  id bigint generated always as identity primary key, at timestamptz not null default now(),
  ip_hash text, email text, gym text, slug text, result text, info jsonb);
create index if not exists signups_at on mf.signups (at);
alter table mf.cfg enable row level security;
alter table mf.signups enable row level security;

create or replace function mf.free_left() returns int language sql stable security definer set search_path to '' as $$
  select greatest(0, coalesce((select (value #>> '{}')::int from mf.cfg where key = 'free_cap'), 50)
    - (select count(*)::int from mf.gyms where plan = 'free' and status in ('ready', 'making')))
$$;

-- for the website: how many free spots are left
create or replace function public.mf_free_left() returns int language sql stable security definer set search_path to '' as $$ select mf.free_left() $$;
revoke all on function public.mf_free_left() from public;
grant execute on function public.mf_free_left() to anon, authenticated;

-- before a sign-up (service role): spots left, the person's account if they have one, the gyms they own, tries from this visitor
create or replace function public.mf_signup_check(p_email text, p_ip text) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
    'free_left', mf.free_left(),
    'user_id', (select id from auth.users where lower(email) = lower(btrim(p_email)) limit 1),
    'owns', coalesce((select jsonb_agg(jsonb_build_object('slug', slug, 'name', name) order by made_at) from mf.gyms where owner_email = lower(btrim(p_email)) and status = 'ready'), '[]'),
    'per_email', coalesce((select (value #>> '{}')::int from mf.cfg where key = 'gyms_per_email'), 3),
    'ip_hour', (select count(*) from mf.signups where ip_hash = p_ip and at > now() - interval '1 hour'),
    'all_hour', (select count(*) from mf.signups where at > now() - interval '1 hour'))
$$;
revoke all on function public.mf_signup_check(text, text) from public, anon, authenticated;
grant execute on function public.mf_signup_check(text, text) to service_role;

create or replace function public.mf_signup_log(p_ip text, p_email text, p_gym text, p_slug text, p_result text, p_info jsonb default null)
returns void language sql security definer set search_path to '' as $$
  insert into mf.signups (ip_hash, email, gym, slug, result, info) values (p_ip, lower(p_email), left(p_gym, 140), p_slug, left(p_result, 300), p_info)
$$;
revoke all on function public.mf_signup_log(text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.mf_signup_log(text, text, text, text, text, jsonb) to service_role;
