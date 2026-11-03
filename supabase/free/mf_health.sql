-- Muay Friend dashboard, part 2: how each gym uses the app, and the money (free project bnglnfdgptvnmugntiom).
-- mf.plan_log keeps every plan change (new paid, upgrade, downgrade, cancel, card failing), written by mf.set_plan.
-- mf_gym_health() reads each gym's own tables for the team dashboard: getting started, last activity, members against the limit.

alter table mf.gyms add column if not exists cancel_reason text;
create table if not exists mf.plan_log (
  id bigserial primary key, at timestamptz not null default now(), slug text not null,
  plan_from text, plan_to text, cycle text, status text, reason text);
create index if not exists plan_log_at on mf.plan_log (at);
alter table mf.plan_log enable row level security;
revoke all on mf.plan_log from anon, authenticated;

-- put a gym on a plan: locks, limits, the plan record, and now a log line when the plan or its payment status changes
create or replace function mf.set_plan(p_slug text, p_plan text, p_info jsonb default '{}') returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare g record; cfg jsonb; pl text := case when p_plan in ('free','gym','gym_plus','camp','master') then p_plan else 'free' end;
begin
  select * into g from mf.gyms where slug = p_slug;
  if g is null then raise exception 'No gym %', p_slug; end if;
  execute format('select coalesce(cfg, ''{}''::jsonb) from %I.platform where id = 1', g.schema_priv) into cfg;
  cfg := coalesce(cfg, '{}'::jsonb) || jsonb_build_object('lock', mf.plan_lock(pl));
  execute format('insert into %I.platform (id, cfg) values (1, %L) on conflict (id) do update set cfg = excluded.cfg', g.schema_priv, cfg::text);
  execute format('insert into %I.app_settings (key, value) values (''plan'', %L) on conflict (key) do update set value = excluded.value', g.schema_pub,
    (jsonb_build_object('name', pl, 'cycle', p_info->>'cycle', 'status', p_info->>'status') || mf.plan_limits(pl))::text);
  if coalesce(g.plan, 'free') <> pl or coalesce(g.plan_status, '') <> coalesce(p_info->>'status', g.plan_status, '') then
    insert into mf.plan_log (slug, plan_from, plan_to, cycle, status, reason)
    values (p_slug, coalesce(g.plan, 'free'), pl, coalesce(p_info->>'cycle', g.plan_cycle), coalesce(p_info->>'status', g.plan_status), nullif(p_info->>'cancel_reason', ''));
  end if;
  update mf.gyms set plan = pl,
    plan_cycle = coalesce(p_info->>'cycle', plan_cycle), plan_status = coalesce(p_info->>'status', plan_status),
    stripe_customer = coalesce(p_info->>'customer', stripe_customer), stripe_sub = coalesce(p_info->>'sub', stripe_sub),
    paid_until = coalesce((p_info->>'paid_until')::timestamptz, paid_until),
    cancel_reason = coalesce(nullif(p_info->>'cancel_reason', ''), cancel_reason)
  where slug = p_slug;
  return jsonb_build_object('slug', p_slug, 'plan', pl);
end $f$;

-- one gym's numbers from its own tables (null if the gym's tables cannot be read)
create or replace function mf.gym_numbers(p_schema text) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare r jsonb;
begin
  execute format($q$
    select jsonb_build_object(
      'members', (select count(*) from %1$I.customers where not coalesce(is_agency, false)),
      'members_7d', (select count(*) from %1$I.customers where not coalesce(is_agency, false) and created_at > now() - interval '7 days'),
      'staff', (select count(*) from %1$I.staff where coalesce(active, true)),
      'packages', (select count(*) from %1$I.packages where coalesce(active, true)),
      'classes', (select count(*) from %1$I.classes),
      'sales', (select count(*) from %1$I.purchases where not coalesce(cancelled, false)),
      'sales_7d', (select count(*) from %1$I.purchases where not coalesce(cancelled, false) and created_at > now() - interval '7 days'),
      'checkins', (select count(*) from %1$I.checkins),
      'checkins_7d', (select count(*) from %1$I.checkins where checked_in_at > now() - interval '7 days'),
      'first_checkin', (select min(checked_in_at) from %1$I.checkins),
      'privates', (select count(*) from %1$I.privates),
      'shop', (select count(*) from %1$I.shop_orders),
      'courses', (select count(*) from %1$I.courses),
      'last', greatest((select max(created_at) from %1$I.customers), (select max(checked_in_at) from %1$I.checkins),
                       (select max(created_at) from %1$I.purchases), (select max(created_at) from %1$I.privates), (select max(created_at) from %1$I.packages)),
      'limit', (select value::jsonb from %1$I.app_settings where key = 'plan'))
  $q$, p_schema) into r;
  return r;
exception when others then return null;
end $f$;
revoke all on function mf.gym_numbers(text) from public, anon, authenticated;

-- every gym with its numbers and a health label, team only
create or replace function public.mf_gym_health() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare g record; n jsonb; out jsonb := '[]'; steps int; lim int; health text; seen timestamptz; last timestamptz;
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can see this.'; end if;
  for g in select * from mf.gyms where status = 'ready' order by made_at desc loop
    n := mf.gym_numbers(g.schema_pub);
    if n is null then out := out || jsonb_build_array(jsonb_build_object('slug', g.slug, 'name', g.name, 'health', 'broken')); continue; end if;
    select last_sign_in_at into seen from auth.users where lower(email) = lower(g.owner_email) limit 1;
    steps := (case when (n->>'members')::int > 0 then 1 else 0 end) + (case when (n->>'packages')::int > 0 then 1 else 0 end)
           + (case when (n->>'classes')::int > 0 then 1 else 0 end) + (case when (n->>'sales')::int > 0 then 1 else 0 end)
           + (case when (n->>'checkins')::int > 0 then 1 else 0 end);
    lim := nullif(n->'limit'->>'members', '')::int;
    last := greatest(nullif(n->>'last', '')::timestamptz, seen);
    health := case
      when lim is not null and (n->>'members')::int >= lim then 'at_limit'
      when lim is not null and (n->>'members')::int >= ceil(lim * 0.8) then 'near_limit'
      when g.made_at > now() - interval '3 days' and steps < 5 then 'new'
      when steps < 3 then 'stuck'
      when last is null or last < now() - interval '7 days' then 'quiet'
      else 'active' end;
    out := out || jsonb_build_array(n - 'limit' || jsonb_build_object('slug', g.slug, 'name', g.name, 'email', g.owner_email, 'plan', coalesce(g.plan, 'free'),
      'cycle', g.plan_cycle, 'pay', g.plan_status, 'made', g.made_at, 'seen', seen, 'last', last, 'steps', steps,
      'limit_members', lim, 'limit_staff', nullif(n->'limit'->>'staff', '')::int, 'health', health));
  end loop;
  return out;
end $f$;
revoke all on function public.mf_gym_health() from public, anon;
grant execute on function public.mf_gym_health() to authenticated;

-- the money, team only. p_days as in mf_dash.
create or replace function public.mf_money(p_days integer default 30) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare d integer := greatest(1, least(coalesce(p_days, 30), 366)); since timestamptz;
  price jsonb := '{"free":0,"gym":1490,"gym_plus":3290,"camp":3990,"master":7990}';
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can see this.'; end if;
  since := date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok' - make_interval(days => d - 1);
  return jsonb_build_object(
    'new_paid', (select count(*) from mf.plan_log where at >= since and plan_from = 'free' and plan_to <> 'free'),
    'upgrades', (select count(*) from mf.plan_log where at >= since and plan_from <> 'free' and plan_to <> 'free' and (price->>plan_to)::int > (price->>plan_from)::int),
    'downgrades', (select count(*) from mf.plan_log where at >= since and plan_from <> 'free' and plan_to <> 'free' and (price->>plan_to)::int < (price->>plan_from)::int),
    'cancels', (select count(*) from mf.plan_log where at >= since and plan_from <> 'free' and plan_to = 'free'),
    'mrr_gained', coalesce((select sum(greatest(0, (price->>plan_to)::int - (price->>plan_from)::int)) from mf.plan_log where at >= since), 0),
    'mrr_lost', coalesce((select sum(greatest(0, (price->>plan_from)::int - (price->>plan_to)::int)) from mf.plan_log where at >= since), 0),
    'ever_paid', (select count(distinct slug) from mf.plan_log where plan_to <> 'free'),
    'gyms_total', (select count(*) from mf.gyms where status = 'ready'),
    'days_to_paid', (select round(avg(extract(epoch from (f.at - g.made_at)) / 86400)) from mf.gyms g
        join (select slug, min(at) at from mf.plan_log where plan_to <> 'free' group by slug) f on f.slug = g.slug),
    'yearly', (select count(*) from mf.gyms where coalesce(plan, 'free') <> 'free' and plan_cycle = 'year'),
    'monthly', (select count(*) from mf.gyms where coalesce(plan, 'free') <> 'free' and coalesce(plan_cycle, 'month') = 'month'),
    'failing', (select coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'name', name, 'email', owner_email, 'plan', plan, 'status', plan_status, 'paid_until', paid_until)), '[]'::jsonb)
        from mf.gyms where plan_status in ('past_due', 'unpaid', 'incomplete')),
    'ending', (select coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'name', name, 'email', owner_email, 'plan', plan, 'paid_until', paid_until, 'reason', cancel_reason)), '[]'::jsonb)
        from mf.gyms where coalesce(plan, 'free') <> 'free' and plan_status = 'canceling'),
    'reasons', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'slug', slug, 'reason', reason) order by at desc), '[]'::jsonb)
        from mf.plan_log where reason is not null and at >= since),
    'log', (select coalesce(jsonb_agg(jsonb_build_object('at', l.at, 'slug', l.slug, 'name', g.name, 'from', l.plan_from, 'to', l.plan_to, 'cycle', l.cycle, 'status', l.status) order by l.at desc), '[]'::jsonb)
        from (select * from mf.plan_log where at >= since order by at desc limit 50) l left join mf.gyms g on g.slug = l.slug));
end $f$;
revoke all on function public.mf_money(integer) from public, anon;
grant execute on function public.mf_money(integer) to authenticated;

do $$ begin
  if position('plan_log' in pg_get_functiondef('mf.set_plan'::regproc)) = 0 then raise exception 'mf.set_plan was not updated'; end if;
end $$;
notify pgrst, 'reload schema';
