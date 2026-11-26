-- Housekeeping calendar (feature hk_calendar, on by default).
-- Housekeeping see the room calendar (who arrives, who leaves, which rooms are full or empty) but cannot change it,
-- and at the top of their list: Check in today (red) and Check out today (purple). Guests show by first name only, no prices.

create or replace function public.housekeeping_calendar(p_from date default null, p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_today date := (now() at time zone private.tz())::date; f date; n int := least(greatest(coalesce(p_days, 14), 1), 31);
begin
  if private.hk_staff() is null and coalesce(private.staff_role(), '') not in ('manager','admin','front_desk','resort') then
    raise exception 'This login cannot see the room calendar.'; end if;
  if not private.feature('hk_calendar', true) then raise exception 'Switched off in Settings, Features.'; end if;
  f := coalesce(p_from, v_today - 1);
  return jsonb_build_object('today', v_today, 'from', f, 'days', n,
    'rooms', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.sort, r.name) from public.rooms r where r.active), '[]'::jsonb),
    'stays', coalesce((select jsonb_agg(jsonb_build_object(
        'room_id', s.room_id, 'check_in', s.check_in, 'check_out', s.check_out, 'status', s.status,
        'who', nullif(split_part(btrim(coalesce(c.name, '')), ' ', 1), ''),
        'guests', nullif(substring(coalesce(to_jsonb(s) ->> 'guests', '') from '^[0-9]+'), '')::int,
        'nights', s.check_out - s.check_in) order by s.check_in)
      from public.stays s left join public.customers c on c.id = s.customer_id
      where s.status in ('booked','in','out') and s.room_id is not null and s.check_in < f + n and s.check_out >= f), '[]'::jsonb));
end $f$;
revoke all on function public.housekeeping_calendar(date, int) from public, anon;
grant execute on function public.housekeeping_calendar(date, int) to authenticated;

notify pgrst, 'reload schema';
