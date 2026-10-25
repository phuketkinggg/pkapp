-- Coaches switch privates on or off themselves (Available / Not available), on top of their weekly hours and closed days.
-- Group classes take priority: with "Group classes block privates" on (Settings, Features, default on) no private can be booked during any class.
alter table public.staff add column if not exists privates_off boolean not null default false;
grant select (privates_off) on public.staff to authenticated;

-- the coach (or the owner or an admin for any coach) turns privates on or off
create or replace function public.coach_privates_set(p_off boolean, p_staff uuid default null) returns jsonb language plpgsql security definer set search_path to '' as $$
declare who uuid := private.hours_who(p_staff);
begin
  update public.staff set privates_off = coalesce(p_off, false) where id = who;
  return private.coach_hours_json(who);
end $$;
revoke all on function public.coach_privates_set(boolean, uuid) from public, anon;
grant execute on function public.coach_privates_set(boolean, uuid) to authenticated;

-- the hours screen shows the switch
create or replace function private.coach_hours_json(p_coach uuid) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('staff_id', p_coach, 'name', (select name from public.staff where id = p_coach),
    'off', coalesce((select privates_off from public.staff where id = p_coach), false),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('dow', h.dow, 'from', to_char(h.from_t,'HH24:MI'), 'to', to_char(h.to_t,'HH24:MI')) order by h.dow, h.from_t)
       from public.coach_hours h where h.staff_id = p_coach), '[]'::jsonb),
    'closed', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'day', c.day, 'from', to_char(c.from_t,'HH24:MI'), 'to', to_char(c.to_t,'HH24:MI'), 'note', c.note) order by c.day, c.from_t nulls first)
       from public.coach_closed c where c.staff_id = p_coach and c.day >= private.bkk_today()), '[]'::jsonb))
$$;

do $$ declare s text;
begin
  -- not available: no free time at all; group classes block every private (switchable)
  s := pg_get_functiondef('private.coach_holds(uuid,date,uuid)'::regprocedure);
  if s not like '%privates_off%' then
    s := replace(s, $a$   where k.blocks_privates and k.start_time is not null$a$, $a$   where (k.blocks_privates or private.feature('classes_block_privates', true)) and k.start_time is not null$a$);
    s := replace(s, $a$  union all
  select coalesce(c.from_t, time '00:00')$a$, $a$  union all
  select time '00:00', time '23:59:59' from public.staff so where so.id = p_coach and so.privates_off
  union all
  select coalesce(c.from_t, time '00:00')$a$);
    if s not like '%privates_off%' or s not like '%classes_block_privates%' then raise exception 'coach_holds patch did not apply'; end if;
    execute s;
  end if;
  -- online booking: a coach who is not available does not show
  s := pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure);
  if s not like '%privates_off%' then
    s := replace(s, $a$from private.bookable_coaches() s)$a$, $a$from private.bookable_coaches() s where not s.privates_off)$a$);
    if s not like '%privates_off%' then raise exception 'private_book_slots patch did not apply'; end if;
    execute s;
  end if;
end $$;
