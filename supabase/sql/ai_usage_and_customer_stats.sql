-- AI usage: every AI call is logged; an optional monthly limit (set by Muay Friend, not by the gym) stops calls when used up.
create table if not exists public.ai_usage(id uuid primary key default gen_random_uuid(), fn text not null, at timestamptz not null default now(), in_tokens int, out_tokens int, ok boolean);
alter table public.ai_usage enable row level security;
revoke all on public.ai_usage from anon, authenticated;
create index if not exists ai_usage_at on public.ai_usage(at);
create table if not exists private.ai_plan(id int primary key default 1 check (id=1), monthly int, note text);
insert into private.ai_plan(id,monthly) values (1,null) on conflict (id) do nothing;
revoke all on private.ai_plan from anon, authenticated;

create or replace function public.ai_usage_take(p_fn text) returns uuid language plpgsql security definer set search_path='' as $f$
declare lim int; used int; v uuid;
begin
  select monthly into lim from private.ai_plan where id=1;
  select count(*) into used from public.ai_usage where at >= (date_trunc('month', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok');
  if lim is not null and used >= lim then return null; end if;
  insert into public.ai_usage(fn) values (left(coalesce(p_fn,'ai'),40)) returning id into v;
  return v;
end $f$;
revoke all on function public.ai_usage_take(text) from public, anon, authenticated;
grant execute on function public.ai_usage_take(text) to service_role;

create or replace function public.ai_usage_summary() returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare m timestamptz := (date_trunc('month', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok');
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return jsonb_build_object(
    'used', (select count(*) from public.ai_usage where at >= m),
    'limit', (select monthly from private.ai_plan where id=1),
    'last_month', (select count(*) from public.ai_usage where at >= m - interval '1 month' and at < m),
    'by_fn', coalesce((select jsonb_object_agg(fn, n) from (select fn, count(*) n from public.ai_usage where at >= m group by fn) x), '{}'::jsonb));
end $f$;
revoke all on function public.ai_usage_summary() from public, anon;
grant execute on function public.ai_usage_summary() to authenticated;

-- Customer stats for the Customers filters: visits (all time and last 30 days), last visit, money paid.
create or replace function public.customer_stats() returns table(customer_id uuid, visits int, visits_30 int, last_visit date, spent int)
language plpgsql stable security definer set search_path='' as $f$
declare d date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if coalesce(private.staff_role(),'') not in ('manager','front_desk') then raise exception 'Only the front desk or a manager can see this.'; end if;
  return query
    select c.id,
      coalesce(v.n,0)::int, coalesce(v.n30,0)::int, v.last,
      coalesce(pay.total,0)::int
    from public.customers c
    left join (select k.customer_id, count(*) n, count(*) filter (where k.day > d-30) n30, max(k.day) last from public.checkins k group by k.customer_id) v on v.customer_id=c.id
    left join (select p.customer_id, sum(p.amount_thb) total from public.payments p where not p.voided and p.customer_id is not null group by p.customer_id) pay on pay.customer_id=c.id;
end $f$;
revoke all on function public.customer_stats() from public, anon;
grant execute on function public.customer_stats() to authenticated;
