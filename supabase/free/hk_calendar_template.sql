delete from mf.template where name like 'hk_calendar:%';
insert into mf.template (ord, phase, kind, name, sql) values (405801, 4, 'patch', 'hk_calendar:405801', $TPL$create or replace function __P__.housekeeping_calendar(p_from date default null, p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_today date := (now() at time zone __Q__.tz())::date; f date; n int := least(greatest(coalesce(p_days, 14), 1), 31);
begin
  if __Q__.hk_staff() is null and coalesce(__Q__.staff_role(), '') not in ('manager','admin','front_desk','resort') then
    raise exception 'This login cannot see the room calendar.'; end if;
  if not __Q__.feature('hk_calendar', true) then raise exception 'Switched off in Settings, Features.'; end if;
  f := coalesce(p_from, v_today - 1);
  return jsonb_build_object('today', v_today, 'from', f, 'days', n,
    'rooms', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.sort, r.name) from __P__.rooms r where r.active), '[]'::jsonb),
    'stays', coalesce((select jsonb_agg(jsonb_build_object(
        'room_id', s.room_id, 'check_in', s.check_in, 'check_out', s.check_out, 'status', s.status,
        'who', nullif(split_part(btrim(coalesce(c.name, '')), ' ', 1), ''),
        'guests', nullif(to_jsonb(s) ->> 'guests', '')::int,
        'nights', s.check_out - s.check_in) order by s.check_in)
      from __P__.stays s left join __P__.customers c on c.id = s.customer_id
      where s.status in ('booked','in','out') and s.room_id is not null and s.check_in < f + n and s.check_out >= f), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199901, 11, 'patch', 'hk_calendar:1199901', $TPL$revoke all on function __P__.housekeeping_calendar(date, int) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199902, 11, 'patch', 'hk_calendar:1199902', $TPL$grant execute on function __P__.housekeeping_calendar(date, int) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'hk_calendar:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
