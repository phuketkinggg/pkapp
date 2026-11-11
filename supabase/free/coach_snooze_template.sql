delete from mf.template where name like 'coach_snooze:%';
insert into mf.template (ord, phase, kind, name, sql) values (302101, 3, 'patch', 'coach_snooze:302101', $TPL$alter table __P__.staff add column if not exists privates_off_until timestamptz;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196101, 11, 'patch', 'coach_snooze:1196101', $TPL$grant select (privates_off_until) on __P__.staff to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000501, 10, 'patch', 'coach_snooze:1000501', $TPL$update __P__.staff set privates_off_until = greatest(coalesce(privates_off_until, now()), ((__Q__.bkk_today() + 1)::timestamp at time zone 'Asia/Bangkok')), privates_off = false
 where privates_off;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402101, 4, 'patch', 'coach_snooze:402101', $TPL$create or replace function __P__.coach_snooze(p_minutes integer, p_staff uuid default null) returns jsonb language plpgsql security definer set search_path to '' as $$
declare who uuid := __Q__.hours_who(p_staff); until timestamptz;
begin
  if coalesce(p_minutes, 0) = -1 then until := (__Q__.bkk_today() + 1)::timestamp at time zone 'Asia/Bangkok';
  elsif coalesce(p_minutes, 0) > 0 then until := now() + make_interval(mins => least(p_minutes, 7 * 24 * 60));
  else until := null; end if;
  update __P__.staff set privates_off_until = until, privates_off = false where id = who;
  return __Q__.coach_hours_json(who);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196102, 11, 'patch', 'coach_snooze:1196102', $TPL$revoke all on function __P__.coach_snooze(integer, uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196103, 11, 'patch', 'coach_snooze:1196103', $TPL$grant execute on function __P__.coach_snooze(integer, uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402102, 4, 'patch', 'coach_snooze:402102', $TPL$create or replace function __P__.coach_privates_set(p_off boolean, p_staff uuid default null) returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  return __P__.coach_snooze(case when coalesce(p_off, false) then -1 else 0 end, p_staff);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402103, 4, 'patch', 'coach_snooze:402103', $TPL$create or replace function __Q__.coach_hours_json(p_coach uuid) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('staff_id', p_coach, 'name', (select name from __P__.staff where id = p_coach),
    'off', coalesce((select privates_off_until > now() from __P__.staff where id = p_coach), false),
    'off_until', (select case when privates_off_until > now() then to_char(privates_off_until at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI') end from __P__.staff where id = p_coach),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('dow', h.dow, 'from', to_char(h.from_t,'HH24:MI'), 'to', to_char(h.to_t,'HH24:MI')) order by h.dow, h.from_t)
       from __P__.coach_hours h where h.staff_id = p_coach), '[]'::jsonb),
    'closed', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'day', c.day, 'from', to_char(c.from_t,'HH24:MI'), 'to', to_char(c.to_t,'HH24:MI'), 'note', c.note) order by c.day, c.from_t nulls first)
       from __P__.coach_closed c where c.staff_id = p_coach and c.day >= __Q__.bkk_today()), '[]'::jsonb))
$$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000502, 10, 'patch', 'coach_snooze:1000502', $TPL$do $p$
declare s text; n text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000503, 10, 'patch', 'coach_snooze:1000503', $TPL$begin
  if to_regprocedure('__Q__.coach_holds(uuid,date,uuid)') is null then raise notice 'no coach_holds here, skipped'; return; end if;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000504, 10, 'patch', 'coach_snooze:1000504', $TPL$s := pg_get_functiondef('__Q__.coach_holds(uuid,date,uuid)'::regprocedure);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000505, 10, 'patch', 'coach_snooze:1000505', $TPL$if position('privates_off_until' in s) > 0 then raise notice 'coach_holds already patched'; return; end if;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000506, 10, 'patch', 'coach_snooze:1000506', $TPL$n := replace(s, $a$select time '00:00', time '23:59:59' from __P__.staff so where so.id = p_coach and so.privates_off$a$,
    $a$select case when p_date = __Q__.bkk_today() then (now() at time zone 'Asia/Bangkok')::time else time '00:00' end,
         case when p_date = (so.privates_off_until at time zone 'Asia/Bangkok')::date then (so.privates_off_until at time zone 'Asia/Bangkok')::time else time '23:59:59' end
    from __P__.staff so where so.id = p_coach and so.privates_off_until > now()
     and p_date between __Q__.bkk_today() and (so.privates_off_until at time zone 'Asia/Bangkok')::date$a$);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000507, 10, 'patch', 'coach_snooze:1000507', $TPL$if n = s then raise notice 'coach_holds: older version, skipped'; return; end if;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000508, 10, 'patch', 'coach_snooze:1000508', $TPL$execute n;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000509, 10, 'patch', 'coach_snooze:1000509', $TPL$if position('privates_off_until' in pg_get_functiondef('__Q__.coach_holds(uuid,date,uuid)'::regprocedure)) = 0 then raise exception 'coach_holds patch did not apply'; end if;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000510, 10, 'patch', 'coach_snooze:1000510', $TPL$end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402104, 4, 'patch', 'coach_snooze:402104', $TPL$create or replace function __P__.coach_avail_now() returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare d date := __Q__.bkk_today(); t time := (now() at time zone 'Asia/Bangkok')::time; dw int := extract(isodow from __Q__.bkk_today())::int - 1;
begin
  if not __Q__.is_desk() then raise exception 'Only the desk can see this.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object('id', s.id, 'name', s.name,
      'off_until', case when s.privates_off_until > now() then to_char(s.privates_off_until at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI') end,
      'hours', coalesce((select jsonb_agg(jsonb_build_object('dow', h.dow, 'from', to_char(h.from_t,'HH24:MI'), 'to', to_char(h.to_t,'HH24:MI')) order by h.dow, h.from_t)
         from __P__.coach_hours h where h.staff_id = s.id), '[]'::jsonb),
      'closed_today', coalesce((select jsonb_agg(jsonb_build_object('from', to_char(c.from_t,'HH24:MI'), 'to', to_char(c.to_t,'HH24:MI'), 'note', c.note) order by c.from_t nulls first)
         from __P__.coach_closed c where c.staff_id = s.id and c.day = d), '[]'::jsonb),
      'privates_today', coalesce((select jsonb_agg(jsonb_build_object('time', to_char(p.start_time,'HH24:MI'), 'to', to_char(p.start_time + make_interval(mins => coalesce(p.minutes,60)),'HH24:MI'),
           'who', coalesce((select c.name from __P__.customers c where c.id = p.customer_id and not coalesce(c.is_agency,false)), p.guest_name, 'Customer')) order by p.start_time)
         from __P__.privates p where p.coach_id = s.id and p.date = d and p.status in ('confirmed','done')), '[]'::jsonb),
      'now', case
        when s.privates_off_until > now() then 'snoozed'
        when exists (select 1 from __P__.coach_closed c where c.staff_id = s.id and c.day = d and (c.from_t is null or t between c.from_t and c.to_t)) then 'closed'
        when exists (select 1 from __P__.privates p where p.coach_id = s.id and p.date = d and p.status in ('confirmed','done')
                       and t >= p.start_time and t < p.start_time + make_interval(mins => coalesce(p.minutes,60))) then 'private'
        when exists (select 1 from __P__.coach_hours h where h.staff_id = s.id and h.dow = dw and t >= h.from_t and t < h.to_t) then 'free'
        else 'off_hours' end,
      'in_hours', exists (select 1 from __P__.coach_hours h where h.staff_id = s.id and h.dow = dw and t >= h.from_t and t < h.to_t)) x
    from __P__.staff s where (s.role = 'coach' or coalesce(s.also_coach, false)) and s.active) q), '[]'::jsonb);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196104, 11, 'patch', 'coach_snooze:1196104', $TPL$revoke all on function __P__.coach_avail_now() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196105, 11, 'patch', 'coach_snooze:1196105', $TPL$grant execute on function __P__.coach_avail_now() to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'coach_snooze:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
