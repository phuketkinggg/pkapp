-- Pause a package (feature package_pause): only the owner, with a reason and who authorised it, after typing their password in the app.
-- While paused the package cannot be used to check in. The days it is paused are added to the end date (and the start-by date
-- of a package not started yet), so the member loses no time. With an end date the days are added at once;
-- without one, they are added when the owner turns the package back on. Every pause is kept in pause_log.
alter table public.purchases add column if not exists paused_from date;
alter table public.purchases add column if not exists paused_until date;
alter table public.purchases add column if not exists pause_reason text;
alter table public.purchases add column if not exists pause_ok_by text;
alter table public.purchases add column if not exists paused_by uuid;
alter table public.purchases add column if not exists pause_days integer not null default 0;
alter table public.purchases add column if not exists pause_log jsonb not null default '[]'::jsonb;

create or replace function private.is_owner() returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.staff s where s.user_id = (select auth.uid()) and s.active and s.role = 'manager')
$$;

create or replace function public.package_pause(p_id uuid, p_from date, p_until date, p_reason text, p_ok_by text) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare p record; me uuid; d int; today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if not private.feature('package_pause', true) then raise exception 'Pausing packages is turned off.'; end if;
  if not private.is_owner() then raise exception 'Only the owner can pause a package.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Say why it is paused.'; end if;
  if coalesce(btrim(p_ok_by), '') = '' then raise exception 'Say who authorised it.'; end if;
  p_from := coalesce(p_from, today);
  if p_until is not null and p_until < p_from then raise exception 'The end date is before the start date.'; end if;
  select * into p from public.purchases where id = p_id for update;
  if p is null then raise exception 'Package not found.'; end if;
  if p.cancelled or p.refunded_at is not null then raise exception 'This package is cancelled or refunded.'; end if;
  if p.paused_from is not null and (p.paused_until is null or p.paused_until >= today) then raise exception 'This package is already paused.'; end if;
  select id into me from public.staff where user_id = (select auth.uid()) and active limit 1;
  d := case when p_until is null then 0 else p_until - p_from + 1 end;
  update public.purchases set
    expires_on = case when expires_on is not null then expires_on + d else expires_on end,
    start_by = case when starts_on is null and start_by is not null then start_by + d else start_by end,
    paused_from = p_from, paused_until = p_until, pause_reason = btrim(p_reason), pause_ok_by = btrim(p_ok_by), paused_by = me, pause_days = d,
    pause_log = pause_log || jsonb_build_array(jsonb_build_object('pause', p_from, 'until', p_until, 'reason', btrim(p_reason), 'ok_by', btrim(p_ok_by), 'by', me, 'at', now()))
  where id = p_id;
  return jsonb_build_object('id', p_id, 'days_added', d);
end $f$;

-- turn it back on from today: the end date moves by the days it was really paused
create or replace function public.package_resume(p_id uuid) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare p record; me uuid; real int; delta int; today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if not private.is_owner() then raise exception 'Only the owner can turn a paused package back on.'; end if;
  select * into p from public.purchases where id = p_id for update;
  if p is null or p.paused_from is null then raise exception 'This package is not paused.'; end if;
  real := greatest(0, least(today - 1, coalesce(p.paused_until, today - 1)) - p.paused_from + 1);
  delta := real - coalesce(p.pause_days, 0);
  select id into me from public.staff where user_id = (select auth.uid()) and active limit 1;
  update public.purchases set
    expires_on = case when expires_on is not null then expires_on + delta else expires_on end,
    start_by = case when starts_on is null and start_by is not null then start_by + delta else start_by end,
    paused_from = null, paused_until = null, pause_reason = null, pause_ok_by = null, paused_by = null, pause_days = 0,
    pause_log = pause_log || jsonb_build_array(jsonb_build_object('resume', today, 'days', real, 'by', me, 'at', now()))
  where id = p_id;
  return jsonb_build_object('id', p_id, 'days_paused', real);
end $f$;
revoke all on function public.package_pause(uuid, date, date, text, text), public.package_resume(uuid), private.is_owner() from public, anon;
grant execute on function public.package_pause(uuid, date, date, text, text), public.package_resume(uuid), private.is_owner() to authenticated;

-- no check in on a paused package, whichever way it is made (desk, kiosk, member app)
create or replace function private.checkin_not_paused() returns trigger language plpgsql security definer set search_path to '' as $f$
declare p record;
begin
  if new.purchase_id is null then return new; end if;
  select paused_from, paused_until, pause_reason into p from public.purchases where id = new.purchase_id;
  if p.paused_from is not null and coalesce(new.day, (now() at time zone 'Asia/Bangkok')::date) >= p.paused_from
     and (p.paused_until is null or coalesce(new.day, (now() at time zone 'Asia/Bangkok')::date) <= p.paused_until) then
    raise exception 'This package is paused%.', coalesce(': ' || p.pause_reason, '');
  end if;
  return new;
end $f$;
drop trigger if exists checkin_not_paused on public.checkins;
create trigger checkin_not_paused before insert on public.checkins for each row execute function private.checkin_not_paused();
notify pgrst, 'reload schema';
