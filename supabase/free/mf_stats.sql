-- Muay Friend website numbers (free project bnglnfdgptvnmugntiom): visits, clicks, enquiries, sign-ups and paid plans, for the team dashboard
-- at muayfriend.com/dash/. Visits are counted without cookies: a visitor is a daily hash of their address and browser (salt in mf.cfg),
-- so nobody can be followed from day to day and no cookie banner is needed.
-- Enquiries (mf_leads) now live here too, moved from the Phuket King database, so Muay Friend has its own sales list.

insert into mf.cfg (key, value) values ('hit_salt', to_jsonb(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))) on conflict (key) do nothing;

create table if not exists mf.hits (
  id bigserial primary key, at timestamptz not null default now(), kind text not null default 'view', -- view, or a click: start, demo, contact, whatsapp, line, price, signup_ok, lead_ok
  path text, lang text, ref text, utm_source text, utm_medium text, utm_campaign text, country text, device text, visitor text);
create index if not exists hits_at on mf.hits (at);
alter table mf.hits enable row level security;
revoke all on mf.hits from anon, authenticated;

create table if not exists public.mf_leads (
  id uuid primary key default gen_random_uuid(), name text not null, email text not null, gym text, country text, members text, phone text, message text,
  source text, ip_hash text, created_at timestamptz not null default now(), emailed boolean, email_error text, plan text, social text,
  status text not null default 'new', welcomed boolean, welcome_error text);
create index if not exists mf_leads_at on public.mf_leads (created_at);
alter table public.mf_leads enable row level security;
revoke all on public.mf_leads from anon, authenticated;

-- one page view or click from the website (public, no login). Quietly ignores bots and floods.
create or replace function public.mf_hit(p jsonb) returns void language plpgsql security definer set search_path to '' as $f$
declare hd jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  ip text := split_part(coalesce(hd->>'cf-connecting-ip', hd->>'x-real-ip', hd->>'x-forwarded-for', ''), ',', 1);
  ua text := left(coalesce(hd->>'user-agent', ''), 300); v text; k text := left(coalesce(p->>'kind', 'view'), 20);
  r text := lower(coalesce(p->>'ref', ''));
begin
  if ua ~* '(bot|crawl|spider|slurp|headless|lighthouse|preview|facebookexternalhit|curl|python|wget)' then return; end if;
  if k !~ '^[a-z_]+$' then return; end if;
  v := left(md5(coalesce((select value #>> '{}' from mf.cfg where key = 'hit_salt'), '') || ip || ua || to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM-DD')), 20);
  if (select count(*) from mf.hits where visitor = v and at > now() - interval '1 minute') >= 30 then return; end if;
  if (select count(*) from mf.hits where at > now() - interval '1 minute') >= 600 then return; end if;
  r := nullif(regexp_replace(regexp_replace(r, '^https?://(www\.)?', ''), '[/?#].*$', ''), '');
  if r like '%muayfriend.com' then r := null; end if;
  insert into mf.hits (kind, path, lang, ref, utm_source, utm_medium, utm_campaign, country, device, visitor)
  values (k, left(p->>'path', 200), left(p->>'lang', 10), left(r, 120), left(lower(p->>'utm_source'), 60), left(lower(p->>'utm_medium'), 60), left(p->>'utm_campaign', 100),
    left(coalesce(nullif(hd->>'cf-ipcountry', ''), nullif(p->>'country', '')), 40),
    case when ua ~* '(ipad|tablet)' then 'tablet' when ua ~* '(mobi|android|iphone)' then 'phone' else 'computer' end, v);
end $f$;
revoke all on function public.mf_hit(jsonb) from public;
grant execute on function public.mf_hit(jsonb) to anon, authenticated;

-- the dashboard numbers, team only. p_days: how far back (1 to 366).
create or replace function public.mf_dash(p_days integer default 30) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare d integer := greatest(1, least(coalesce(p_days, 30), 366)); since timestamptz; prev timestamptz;
  price jsonb := '{"gym":1490,"gym_plus":3290,"camp":3990,"master":7990}';
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can see this.'; end if;
  since := date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok' - make_interval(days => d - 1);
  prev := since - make_interval(days => d);
  return jsonb_build_object(
    'days', d,
    'totals', (select jsonb_build_object('views', count(*) filter (where kind = 'view'), 'visitors', count(distinct visitor) filter (where kind = 'view'),
        'start', count(*) filter (where kind = 'start'), 'demo', count(*) filter (where kind = 'demo'), 'contact', count(*) filter (where kind in ('contact', 'whatsapp', 'line')),
        'price', count(*) filter (where kind = 'price'))
      from mf.hits where at >= since),
    'before', (select jsonb_build_object('views', count(*) filter (where kind = 'view'), 'visitors', count(distinct visitor) filter (where kind = 'view'))
      from mf.hits where at >= prev and at < since),
    'today', (select jsonb_build_object('views', count(*) filter (where kind = 'view'), 'visitors', count(distinct visitor) filter (where kind = 'view'))
      from mf.hits where at >= date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok'),
    'live', (select count(distinct visitor) from mf.hits where at > now() - interval '5 minutes'),
    'by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'views', views, 'visitors', visitors) order by day), '[]'::jsonb) from (
        select g::date as day, count(h.id) filter (where h.kind = 'view') as views, count(distinct h.visitor) filter (where h.kind = 'view') as visitors
        from generate_series((since at time zone 'Asia/Bangkok')::date, (now() at time zone 'Asia/Bangkok')::date, interval '1 day') g
        left join mf.hits h on (h.at at time zone 'Asia/Bangkok')::date = g::date and h.at >= since
        group by g) x),
    'pages', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc), '[]'::jsonb) from (
        select coalesce(path, '/') k, count(*) n from mf.hits where at >= since and kind = 'view' group by 1 order by 2 desc limit 12) x),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc), '[]'::jsonb) from (
        select case when utm_source is not null then utm_source || coalesce(' (' || utm_campaign || ')', '')
                    when ref is null then 'Direct (typed or bookmarked)'
                    when ref ~ '(facebook|fb\.|instagram|messenger)' then 'Facebook and Instagram'
                    when ref ~ 'google\.' then 'Google'
                    when ref ~ '(tiktok)' then 'TikTok'
                    when ref ~ '(youtube|youtu\.be)' then 'YouTube'
                    when ref ~ '(line\.me)' then 'LINE'
                    else ref end k, count(distinct visitor) n
        from mf.hits where at >= since and kind = 'view' group by 1 order by 2 desc limit 12) x),
    'countries', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc), '[]'::jsonb) from (
        select coalesce(country, 'Unknown') k, count(distinct visitor) n from mf.hits where at >= since and kind = 'view' group by 1 order by 2 desc limit 12) x),
    'devices', (select coalesce(jsonb_object_agg(device, n), '{}'::jsonb) from (
        select coalesce(device, 'computer') device, count(distinct visitor) n from mf.hits where at >= since and kind = 'view' group by 1) x),
    'langs', (select coalesce(jsonb_object_agg(l, n), '{}'::jsonb) from (
        select coalesce(lang, 'en') l, count(distinct visitor) n from mf.hits where at >= since and kind = 'view' group by 1) x),
    'leads', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'at', created_at, 'name', name, 'email', email, 'gym', gym, 'country', country, 'members', members,
        'phone', phone, 'social', social, 'message', message, 'plan', plan, 'status', status) order by created_at desc), '[]'::jsonb)
      from (select * from public.mf_leads where created_at >= since order by created_at desc limit 200) x),
    'signups', (select coalesce(jsonb_agg(jsonb_build_object('at', made_at, 'gym', name, 'slug', slug, 'email', owner_email, 'plan', plan, 'status', plan_status,
        'cycle', plan_cycle) order by made_at desc), '[]'::jsonb) from mf.gyms where made_at >= since),
    'signup_tries', (select count(*) from mf.signups where at >= since),
    'gyms', (select jsonb_build_object('total', count(*), 'free', count(*) filter (where coalesce(plan, 'free') = 'free'),
        'paid', count(*) filter (where coalesce(plan, 'free') <> 'free'),
        'by_plan', (select coalesce(jsonb_object_agg(plan, n), '{}'::jsonb) from (select coalesce(plan, 'free') plan, count(*) n from mf.gyms group by 1) y),
        'mrr_thb', coalesce(sum(case when coalesce(plan, 'free') = 'free' then 0
                                     when plan_cycle = 'year' then round((price->>plan)::numeric * 10 / 12)
                                     else (price->>plan)::numeric end), 0))
      from mf.gyms));
end $f$;
revoke all on function public.mf_dash(integer) from public, anon;
grant execute on function public.mf_dash(integer) to authenticated;

-- mark an enquiry (new, contacted, won, lost)
create or replace function public.mf_lead_status(p_id uuid, p_status text) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can change this.'; end if;
  if p_status not in ('new', 'contacted', 'won', 'lost', 'rejected') then raise exception 'Unknown status.'; end if;
  update public.mf_leads set status = p_status where id = p_id;
end $f$;
revoke all on function public.mf_lead_status(uuid, text) from public, anon;
grant execute on function public.mf_lead_status(uuid, text) to authenticated;
notify pgrst, 'reload schema';
