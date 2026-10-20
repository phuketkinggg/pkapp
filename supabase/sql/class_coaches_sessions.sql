-- Group class clock-in follows the coaches on each class.
-- Once any class has coaches set, the clock-in times come from the classes (start and end time, or 90 minutes if no end),
-- and only the coaches on a class (not on holiday) are expected to clock in for it. Before that, the old settings list is used.

create or replace function private.coach_sessions(d date) returns table(s time, e time) language sql stable security definer set search_path='' as $f$
  select q.s, q.e from (
    select (x->>'start')::time s, (x->>'end')::time e
    from jsonb_array_elements(coalesce((select value::jsonb from public.app_settings where key = 'coach_sessions'), '[]'::jsonb)) x
    where private.sessions_on()
      and (extract(isodow from d)::int - 1) in (select jsonb_array_elements_text(x->'days')::int)
      and not (exists (select 1 from public.classes k where k.day = extract(isodow from d)::int - 1 and k.start_time = (x->>'start')::time)
           and not exists (select 1 from public.classes k where k.day = extract(isodow from d)::int - 1 and k.start_time = (x->>'start')::time
                           and not (k.off_from is not null and d between k.off_from and coalesce(k.off_to, k.off_from))))
    union all
    select k.start_time, max(coalesce(k.end_time, (k.start_time + interval '90 minutes')::time))
    from public.classes k
    where not private.sessions_on() and k.start_time is not null and k.day = extract(isodow from d)::int - 1 and cardinality(k.coach_ids) > 0
      and not (k.off_from is not null and d between k.off_from and coalesce(k.off_to, k.off_from))
    group by k.start_time
  ) q order by 1
$f$;

-- who is expected at a group class time: the coaches on the classes at that time, minus anyone on approved holiday
create or replace function private.session_coaches(d date, p_s time) returns uuid[] language sql stable security definer set search_path='' as $f$
  select coalesce(array_agg(st.id order by st.name), '{}') from public.staff st
  where st.active and st.role = 'coach' and not private.on_holiday(st.id, d)
    and (private.sessions_on() or exists (
      select 1 from public.classes k where k.day = extract(isodow from d)::int - 1 and k.start_time = p_s and st.id = any(k.coach_ids)
        and not (k.off_from is not null and d between k.off_from and coalesce(k.off_to, k.off_from))))
$f$;

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.staff_clock_today()'::regprocedure);
  n := replace(d, 'from private.coach_sessions(t) x)', 'from private.coach_sessions(t) x where me = any(private.session_coaches(t, x.s)))');
  n := replace(n, 'case when r = ''coach'' and private.sessions_on() and not private.on_holiday(me, t) then', 'case when r = ''coach'' and not private.on_holiday(me, t) then');
  n := replace(n, 'where me = any(k.coach_ids) and not private.on_holiday(me, t) and k.day', 'where private.sessions_on() and me = any(k.coach_ids) and not private.on_holiday(me, t) and k.day');
  if n = d then raise exception 'staff_clock_today not changed'; end if;
  execute n;

  d := pg_get_functiondef('public.staff_hours(date,date)'::regprocedure);
  n := replace(d, 'join public.staff st on st.role = ''coach'' and st.active', 'join public.staff st on st.id = any(private.session_coaches(g.d, x.s))');
  n := replace(n, '
        and private.sessions_on()
        and not private.on_holiday(st.id, g.d)', '
        and not private.on_holiday(st.id, g.d)');
  n := replace(n, 'join public.staff s on s.id = any(k.coach_ids) and s.active', 'join public.staff s on s.id = any(k.coach_ids) and s.active and private.sessions_on()');
  if n = d then raise exception 'staff_hours not changed'; end if;
  execute n;

  d := pg_get_functiondef('public.coach_board(date,date)'::regprocedure);
  n := replace(d, 'where st.role = ''coach'' and st.active))', 'where st.id = any(private.session_coaches(g.d, x.s))))');
  if n = d then raise exception 'coach_board not changed'; end if;
  execute n;
end $$;
