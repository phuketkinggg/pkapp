-- Website numbers: what visitors do on www.phuketking.com, step by step, so the owner can see where people stop.
-- The website sends small anonymous events (no names, emails or IP addresses): a random visitor id kept in the browser,
-- a random visit id, the page, where they came from (Google, Facebook...), phone or computer, and the step.
-- Orders and stays come from the real records, so "paid" is always the truth.

create table if not exists public.site_events (
  id bigserial primary key,
  at timestamptz not null default now(),
  vid text not null,
  sid text not null,
  ev text not null,
  page text,
  src text,
  dev text,
  item text
);
create index if not exists site_events_at on public.site_events (at);
create index if not exists site_events_sid on public.site_events (sid, at);
alter table public.site_events enable row level security;
revoke all on public.site_events from anon, authenticated;

create or replace function public.site_track(p jsonb) returns void language plpgsql security definer set search_path to '' as $$
declare ev text := left(coalesce(p->>'ev',''), 20); s text := left(coalesce(p->>'sid',''), 24);
begin
  if ev not in ('view','buy_open','buy_pay','buy_private','stay_dates','stay_full','stay_room','stay_pay','shop_add','shop_pay','wa','chat') then return; end if;
  if s !~ '^[A-Za-z0-9]{8,24}$' or coalesce(p->>'vid','') !~ '^[A-Za-z0-9]{8,24}$' then return; end if;
  -- a visit sends at most 200 events, and the site at most 100,000 a day
  if (select count(*) from public.site_events where sid = s and at > now() - interval '6 hours') >= 200 then return; end if;
  if (select count(*) from public.site_events where at > now() - interval '1 day') >= 100000 then return; end if;
  insert into public.site_events (vid, sid, ev, page, src, dev, item)
  values (p->>'vid', s, ev, left(nullif(p->>'page',''), 80), left(nullif(p->>'src',''), 40), case when p->>'dev' in ('m','d') then p->>'dev' end, left(nullif(p->>'item',''), 120));
end $$;
revoke all on function public.site_track(jsonb) from public;
grant execute on function public.site_track(jsonb) to anon, authenticated;

-- the owner's report for a date range (Bangkok dates)
create or replace function public.site_stats(p_from date, p_to date) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare a timestamptz; b timestamptz;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can see the website numbers.'; end if;
  if p_to < p_from or p_to - p_from > 400 then raise exception 'Choose up to 400 days.'; end if;
  a := (p_from::timestamp) at time zone 'Asia/Bangkok'; b := ((p_to + 1)::timestamp) at time zone 'Asia/Bangkok';
  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'totals', (select jsonb_build_object('visitors', count(distinct vid), 'visits', count(distinct sid), 'views', count(*) filter (where ev = 'view'),
        'phone', count(distinct vid) filter (where dev = 'm'), 'computer', count(distinct vid) filter (where dev = 'd'),
        'wa', count(distinct sid) filter (where ev = 'wa'), 'chat', count(distinct sid) filter (where ev = 'chat'))
      from public.site_events where at >= a and at < b),
    'days', coalesce((select jsonb_agg(x order by x->>'d') from (
        select jsonb_build_object('d', (at at time zone 'Asia/Bangkok')::date, 'visitors', count(distinct vid), 'views', count(*) filter (where ev = 'view'),
          'buy_open', count(distinct sid) filter (where ev = 'buy_open'), 'stay_dates', count(distinct sid) filter (where ev = 'stay_dates'),
          'pay', count(distinct sid) filter (where ev in ('buy_pay','stay_pay','shop_pay')), 'wa', count(distinct sid) filter (where ev = 'wa')) x
        from public.site_events where at >= a and at < b group by (at at time zone 'Asia/Bangkok')::date) z), '[]'::jsonb),
    'stay', (select jsonb_build_object(
        'page', count(distinct sid) filter (where ev = 'view' and page like '/book%'),
        'dates', count(distinct sid) filter (where ev = 'stay_dates'),
        'full', count(distinct sid) filter (where ev = 'stay_full'),
        'room', count(distinct sid) filter (where ev = 'stay_room'),
        'pay', count(distinct sid) filter (where ev = 'stay_pay'))
      from public.site_events where at >= a and at < b)
      || (select jsonb_build_object('started', count(*), 'paid', count(*) filter (where s.status <> 'cancelled' and s.hold_until is null),
            'revenue', coalesce(sum(s.room_price_thb) filter (where s.status <> 'cancelled' and s.hold_until is null), 0))
          from public.stays s where s.external_id like 'web:%' and s.created_at >= a and s.created_at < b and coalesce(s.notes,'') not like '%Website test%'),
    'pkg', (select jsonb_build_object(
        'page', count(distinct sid) filter (where ev = 'view' and page like '/prices%'),
        'open', count(distinct sid) filter (where ev = 'buy_open'),
        'private', count(distinct sid) filter (where ev = 'buy_private'),
        'pay', count(distinct sid) filter (where ev = 'buy_pay'))
      from public.site_events where at >= a and at < b)
      || (select jsonb_build_object('started', count(*), 'paid', count(*) filter (where o.status = 'paid'), 'revenue', coalesce(sum(o.price_thb) filter (where o.status = 'paid'), 0))
          from public.web_pkg_orders o where o.created_at >= a and o.created_at < b and o.email not like 'zz-%'),
    'shop', (select jsonb_build_object('add', count(distinct sid) filter (where ev = 'shop_add'), 'pay', count(distinct sid) filter (where ev = 'shop_pay'))
      from public.site_events where at >= a and at < b),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('src', src, 'visitors', n) order by n desc) from (
        select coalesce(src,'Direct') src, count(distinct vid) n from public.site_events where at >= a and at < b and ev = 'view' group by 1 order by 2 desc limit 12) z), '[]'::jsonb),
    'pages', coalesce((select jsonb_agg(jsonb_build_object('page', page, 'views', v, 'visitors', n) order by v desc) from (
        select coalesce(page,'/') page, count(*) v, count(distinct vid) n from public.site_events where at >= a and at < b and ev = 'view' group by 1 order by 2 desc limit 15) z), '[]'::jsonb),
    'packages', coalesce((select jsonb_agg(jsonb_build_object('item', item, 'open', o, 'pay', p) order by o desc) from (
        select item, count(distinct sid) filter (where ev = 'buy_open') o, count(distinct sid) filter (where ev = 'buy_pay') p
        from public.site_events where at >= a and at < b and ev in ('buy_open','buy_pay') and item is not null group by 1 order by 2 desc limit 15) z), '[]'::jsonb),
    'nights', coalesce((select jsonb_agg(jsonb_build_object('item', item, 'n', n) order by n desc) from (
        select item, count(distinct sid) n from public.site_events where at >= a and at < b and ev = 'stay_dates' and item is not null group by 1 order by 2 desc limit 10) z), '[]'::jsonb),
    'wa_pages', coalesce((select jsonb_agg(jsonb_build_object('page', page, 'n', n) order by n desc) from (
        select coalesce(page,'/') page, count(distinct sid) n from public.site_events where at >= a and at < b and ev = 'wa' group by 1 order by 2 desc limit 10) z), '[]'::jsonb)
  );
end $$;
revoke all on function public.site_stats(date, date) from public, anon;
grant execute on function public.site_stats(date, date) to authenticated;

-- the website offer for room bookings, read by the booking page (book function): direct booking discount and a gift for long stays
insert into public.app_settings (key, value)
select 'stay_offer', '{"on":true,"pct":10,"gift_nights":7,"gift":"a free Phuket King training top"}'
where not exists (select 1 from public.app_settings where key = 'stay_offer');
