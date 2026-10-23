-- Website numbers, more detail: where visitors are (by their clock, no IP), their language, ad campaigns,
-- the first page of each visit, new or returning, time on the site, engaged visits and bounces, busy hours,
-- taps on phone, email, map and social links, and old links that show "page not found".
alter table public.site_events add column if not exists tz text;
alter table public.site_events add column if not exists lang text;
alter table public.site_events add column if not exists camp text;
create index if not exists site_events_vid on public.site_events (vid, at);

create or replace function public.site_track(p jsonb) returns void language plpgsql security definer set search_path to '' as $$
declare ev text := left(coalesce(p->>'ev',''), 20); s text := left(coalesce(p->>'sid',''), 24);
  z text := nullif(p->>'tz',''); l text := nullif(p->>'lang',''); c text := left(nullif(btrim(coalesce(p->>'camp','')),''), 60);
begin
  if ev not in ('view','buy_open','buy_pay','buy_private','stay_dates','stay_full','stay_room','stay_pay','shop_add','shop_pay','wa','chat',
                'engaged','time','click','nf') then return; end if;
  if s !~ '^[A-Za-z0-9]{8,24}$' or coalesce(p->>'vid','') !~ '^[A-Za-z0-9]{8,24}$' then return; end if;
  if z is not null and (length(z) > 40 or z !~ '^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$') then z := null; end if;
  if l is not null and (length(l) > 15 or l !~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$') then l := null; end if;
  -- a visit sends at most 300 events, and the site at most 100,000 a day
  if (select count(*) from public.site_events where sid = s and at > now() - interval '6 hours') >= 300 then return; end if;
  if (select count(*) from public.site_events where at > now() - interval '1 day') >= 100000 then return; end if;
  insert into public.site_events (vid, sid, ev, page, src, dev, item, tz, lang, camp)
  values (p->>'vid', s, ev, left(nullif(p->>'page',''), 80), left(nullif(p->>'src',''), 40), case when p->>'dev' in ('m','d') then p->>'dev' end,
          left(nullif(p->>'item',''), 120), z, l, c);
end $$;
revoke all on function public.site_track(jsonb) from public;
grant execute on function public.site_track(jsonb) to anon, authenticated;

-- the extra parts of the report
create or replace function private.site_more(a timestamptz, b timestamptz) returns jsonb language sql stable security definer set search_path to '' as $$
  with e as (select * from public.site_events where at >= a and at < b),
  v as (select sid, min(vid) vid,
          count(*) filter (where ev = 'view') views,
          bool_or(ev in ('engaged','buy_open','stay_dates','shop_add','wa','chat','click')) eng,
          bool_or(ev in ('wa','chat','buy_pay','stay_pay','shop_pay')) act,
          sum(least(case when ev = 'time' and item ~ '^[0-9]{1,5}$' then item::int end, 1800)) secs,
          (array_agg(page order by at) filter (where ev = 'view'))[1] land,
          max(tz) tz, max(lang) lang, max(camp) camp, coalesce(max(src),'Direct') src
        from e group by sid),
  firsts as (select vid, min(at) f from public.site_events where vid in (select distinct vid from e) group by vid)
  select jsonb_build_object(
    'visits', (select jsonb_build_object(
        'visits', count(*), 'bounce', count(*) filter (where views <= 1 and not eng), 'engaged', count(*) filter (where eng),
        'avg_secs', coalesce(round(avg(secs) filter (where secs > 0)), 0),
        'new', (select count(*) from firsts where f >= a), 'returning', (select count(*) from firsts where f < a))
      from v),
    'countries', coalesce((select jsonb_agg(jsonb_build_object('tz', tz, 'n', n) order by n desc) from (
        select coalesce(tz,'') tz, count(*) n from v group by 1 order by 2 desc limit 60) z), '[]'::jsonb),
    'langs', coalesce((select jsonb_agg(jsonb_build_object('lang', lg, 'n', n) order by n desc) from (
        select lower(left(coalesce(lang,'?'),2)) lg, count(*) n from v group by 1 order by 2 desc limit 15) z), '[]'::jsonb),
    'landing', coalesce((select jsonb_agg(jsonb_build_object('page', land, 'visits', n, 'bounce', bo, 'secs', s, 'act', ac) order by n desc) from (
        select coalesce(land,'/') land, count(*) n, count(*) filter (where views <= 1 and not eng) bo,
               coalesce(round(avg(secs) filter (where secs > 0)), 0) s, count(*) filter (where act) ac
        from v where land is not null group by 1 order by 2 desc limit 15) z), '[]'::jsonb),
    'src_more', coalesce((select jsonb_agg(jsonb_build_object('src', src, 'visits', n, 'bounce', bo, 'secs', s, 'act', ac) order by n desc) from (
        select src, count(*) n, count(*) filter (where views <= 1 and not eng) bo, coalesce(round(avg(secs) filter (where secs > 0)), 0) s,
               count(*) filter (where act) ac
        from v group by 1 order by 2 desc limit 15) z), '[]'::jsonb),
    'camps', coalesce((select jsonb_agg(jsonb_build_object('camp', camp, 'visits', n, 'act', ac) order by n desc) from (
        select camp, count(*) n, count(*) filter (where act) ac from v where camp is not null group by 1 order by 2 desc limit 15) z), '[]'::jsonb),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('h', hr, 'n', n) order by hr) from (
        select extract(hour from at at time zone 'Asia/Bangkok')::int hr, count(distinct sid) n from e where ev = 'view' group by 1) z), '[]'::jsonb),
    'page_time', coalesce((select jsonb_agg(jsonb_build_object('page', page, 'secs', s, 'reads', n) order by n desc) from (
        select coalesce(page,'/') page, round(avg(least(item::int,1800))) s, count(*) n
        from e where ev = 'time' and item ~ '^[0-9]{1,5}$' and item::int > 0 group by 1 order by 3 desc limit 20) z), '[]'::jsonb),
    'clicks', coalesce((select jsonb_agg(jsonb_build_object('item', item, 'n', n) order by n desc) from (
        select item, count(distinct sid) n from e where ev = 'click' and item is not null group by 1 order by 2 desc limit 12) z), '[]'::jsonb),
    'notfound', coalesce((select jsonb_agg(jsonb_build_object('item', item, 'n', n, 'src', s) order by n desc) from (
        select item, count(*) n, string_agg(distinct src, ', ') s from e where ev = 'nf' and item is not null group by 1 order by 2 desc limit 20) z), '[]'::jsonb),
    'devices', (select jsonb_build_object('m', count(*) filter (where d = 'm'), 'd', count(*) filter (where d = 'd'),
                 'm_act', count(*) filter (where d = 'm' and ac), 'd_act', count(*) filter (where d = 'd' and ac))
        from (select sid, max(dev) d, bool_or(ev in ('wa','chat','buy_pay','stay_pay','shop_pay')) ac from e group by sid) z)
  )
$$;
revoke all on function private.site_more(timestamptz, timestamptz) from public, anon, authenticated;

-- the report now adds the extra parts
do $$ declare d text := pg_get_functiondef('public.site_stats(date, date)'::regprocedure); begin
  if position('private.site_more' in d) = 0 then
    d := replace(d, $a$  return jsonb_build_object($a$, $b$  return private.site_more(a, b) || jsonb_build_object($b$);
    if position('private.site_more' in d) = 0 then raise exception 'site_stats patch did not apply'; end if;
    execute d;
  end if;
end $$;
