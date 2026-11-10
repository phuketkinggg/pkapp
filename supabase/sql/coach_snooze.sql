-- Coach availability for privates: Not available is now a snooze for a set time (30 minutes, 1, 2 or 4 hours, or the rest of
-- today), not an open ended switch. Only the snoozed time is blocked: privates can still be booked for later today, the next
-- days, and privates already done can be added. When the time is up the coach is available again by themselves.
-- And a live overview for the desk (Staff hours): every coach's private hours this week and whether they are free right now.
-- Needs coach_avail.sql. Patches check they applied and skip cleanly where a database is older.

alter table public.staff add column if not exists privates_off_until timestamptz;
grant select (privates_off_until) on public.staff to authenticated;

-- the old open ended switch becomes a snooze until the end of today, so nobody stays off by accident
update public.staff set privates_off_until = greatest(coalesce(privates_off_until, now()), ((private.bkk_today() + 1)::timestamp at time zone 'Asia/Bangkok')), privates_off = false
 where privates_off;

-- the coach (or a manager or the desk for any coach): snooze for p_minutes, 0 or null = available again, -1 = the rest of today
create or replace function public.coach_snooze(p_minutes integer, p_staff uuid default null) returns jsonb language plpgsql security definer set search_path to '' as $$
declare who uuid := private.hours_who(p_staff); until timestamptz;
begin
  if coalesce(p_minutes, 0) = -1 then until := (private.bkk_today() + 1)::timestamp at time zone 'Asia/Bangkok';
  elsif coalesce(p_minutes, 0) > 0 then until := now() + make_interval(mins => least(p_minutes, 7 * 24 * 60));
  else until := null; end if;
  update public.staff set privates_off_until = until, privates_off = false where id = who;
  return private.coach_hours_json(who);
end $$;
revoke all on function public.coach_snooze(integer, uuid) from public, anon;
grant execute on function public.coach_snooze(integer, uuid) to authenticated;

-- the old switch (older app versions): on = snooze for the rest of today
create or replace function public.coach_privates_set(p_off boolean, p_staff uuid default null) returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  return public.coach_snooze(case when coalesce(p_off, false) then -1 else 0 end, p_staff);
end $$;

-- the hours screen: off while snoozed, and until when
create or replace function private.coach_hours_json(p_coach uuid) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('staff_id', p_coach, 'name', (select name from public.staff where id = p_coach),
    'off', coalesce((select privates_off_until > now() from public.staff where id = p_coach), false),
    'off_until', (select case when privates_off_until > now() then to_char(privates_off_until at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI') end from public.staff where id = p_coach),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('dow', h.dow, 'from', to_char(h.from_t,'HH24:MI'), 'to', to_char(h.to_t,'HH24:MI')) order by h.dow, h.from_t)
       from public.coach_hours h where h.staff_id = p_coach), '[]'::jsonb),
    'closed', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'day', c.day, 'from', to_char(c.from_t,'HH24:MI'), 'to', to_char(c.to_t,'HH24:MI'), 'note', c.note) order by c.day, c.from_t nulls first)
       from public.coach_closed c where c.staff_id = p_coach and c.day >= private.bkk_today()), '[]'::jsonb))
$$;

-- booking: a snoozed coach is blocked only from now until the snooze ends (patched, checking it applied)
do $p$
declare s text; n text;
begin
  if to_regprocedure('private.coach_holds(uuid,date,uuid)') is null then raise notice 'no coach_holds here, skipped'; return; end if;
  s := pg_get_functiondef('private.coach_holds(uuid,date,uuid)'::regprocedure);
  if position('privates_off_until' in s) > 0 then raise notice 'coach_holds already patched'; return; end if;
  n := replace(s, $a$select time '00:00', time '23:59:59' from public.staff so where so.id = p_coach and so.privates_off$a$,
    $a$select case when p_date = private.bkk_today() then (now() at time zone 'Asia/Bangkok')::time else time '00:00' end,
         case when p_date = (so.privates_off_until at time zone 'Asia/Bangkok')::date then (so.privates_off_until at time zone 'Asia/Bangkok')::time else time '23:59:59' end
    from public.staff so where so.id = p_coach and so.privates_off_until > now()
     and p_date between private.bkk_today() and (so.privates_off_until at time zone 'Asia/Bangkok')::date$a$);
  if n = s then raise notice 'coach_holds: older version, skipped'; return; end if;
  execute n;
  if position('privates_off_until' in pg_get_functiondef('private.coach_holds(uuid,date,uuid)'::regprocedure)) = 0 then raise exception 'coach_holds patch did not apply'; end if;
end $p$;

-- the desk: every coach who takes privates, their hours, and what they are doing right now
create or replace function public.coach_avail_now() returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare d date := private.bkk_today(); t time := (now() at time zone 'Asia/Bangkok')::time; dw int := extract(isodow from private.bkk_today())::int - 1;
begin
  if not private.is_desk() then raise exception 'Only the desk can see this.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object('id', s.id, 'name', s.name,
      'off_until', case when s.privates_off_until > now() then to_char(s.privates_off_until at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI') end,
      'hours', coalesce((select jsonb_agg(jsonb_build_object('dow', h.dow, 'from', to_char(h.from_t,'HH24:MI'), 'to', to_char(h.to_t,'HH24:MI')) order by h.dow, h.from_t)
         from public.coach_hours h where h.staff_id = s.id), '[]'::jsonb),
      'closed_today', coalesce((select jsonb_agg(jsonb_build_object('from', to_char(c.from_t,'HH24:MI'), 'to', to_char(c.to_t,'HH24:MI'), 'note', c.note) order by c.from_t nulls first)
         from public.coach_closed c where c.staff_id = s.id and c.day = d), '[]'::jsonb),
      'privates_today', coalesce((select jsonb_agg(jsonb_build_object('time', to_char(p.start_time,'HH24:MI'), 'to', to_char(p.start_time + make_interval(mins => coalesce(p.minutes,60)),'HH24:MI'),
           'who', coalesce((select c.name from public.customers c where c.id = p.customer_id and not coalesce(c.is_agency,false)), p.guest_name, 'Customer')) order by p.start_time)
         from public.privates p where p.coach_id = s.id and p.date = d and p.status in ('confirmed','done')), '[]'::jsonb),
      'now', case
        when s.privates_off_until > now() then 'snoozed'
        when exists (select 1 from public.coach_closed c where c.staff_id = s.id and c.day = d and (c.from_t is null or t between c.from_t and c.to_t)) then 'closed'
        when exists (select 1 from public.privates p where p.coach_id = s.id and p.date = d and p.status in ('confirmed','done')
                       and t >= p.start_time and t < p.start_time + make_interval(mins => coalesce(p.minutes,60))) then 'private'
        when exists (select 1 from public.coach_hours h where h.staff_id = s.id and h.dow = dw and t >= h.from_t and t < h.to_t) then 'free'
        else 'off_hours' end,
      'in_hours', exists (select 1 from public.coach_hours h where h.staff_id = s.id and h.dow = dw and t >= h.from_t and t < h.to_t)) x
    from public.staff s where (s.role = 'coach' or coalesce(s.also_coach, false)) and s.active) q), '[]'::jsonb);
end $$;
revoke all on function public.coach_avail_now() from public, anon;
grant execute on function public.coach_avail_now() to authenticated;

notify pgrst, 'reload schema';
