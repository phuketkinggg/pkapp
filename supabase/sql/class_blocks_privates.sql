-- Some classes use the hall, so no private can be booked at the same time (yoga Monday, Wednesday and Friday 9:45 to 10:45).
-- A class with blocks_privates holds that time for every coach, on the weeks it runs (not when it is off).
-- A class without an end time blocks one hour.
alter table public.classes add column if not exists blocks_privates boolean not null default false;

-- the yoga classes now
update public.classes set blocks_privates = true, end_time = coalesce(end_time, time '10:45')
 where discipline = 'Yoga' and start_time = time '09:45' and not blocks_privates;

-- held time also covers classes that block privates on that day
create or replace function private.coach_holds(p_coach uuid, p_date date, p_except uuid default null)
returns table (b_from time, b_to time) language sql stable security definer set search_path to '' as $$
  select x.start_time, x.start_time + make_interval(mins => x.minutes) from public.privates x
   where x.status = 'requested' and coalesce(x.coach_id, x.preferred_coach_id) = p_coach and x.date = p_date
     and x.coach_answer is distinct from 'no' and (p_except is null or x.id <> p_except)
  union all
  select x.alt_time, x.alt_time + make_interval(mins => x.minutes) from public.privates x
   where x.status = 'requested' and coalesce(x.coach_id, x.preferred_coach_id) = p_coach and x.alt_date = p_date and x.alt_time is not null
     and (p_except is null or x.id <> p_except)
  union all
  select (o.private_req->>k.t)::time, (o.private_req->>k.t)::time + interval '60 minutes'
    from public.web_pkg_orders o cross join (values ('date','time'), ('alt_date','alt_time')) k(d, t)
   where o.status = 'waiting' and o.private_req is not null and (o.private_req->>'coach')::uuid = p_coach
     and o.private_req->>k.d = to_char(p_date, 'YYYY-MM-DD') and nullif(o.private_req->>k.t, '') is not null
     and o.email is distinct from nullif(current_setting('pk.hold_email', true), '')
     and (o.created_at > now() - interval '45 minutes'
          or exists (select 1 from public.pay_claims c where c.kind = 'webpkg' and c.ref_id = o.id and c.status = 'waiting'))
  union all
  select coalesce(c.from_t, time '00:00'), coalesce(c.to_t, time '23:59:59') from public.coach_closed c
   where c.staff_id = p_coach and c.day = p_date
  union all
  select k.start_time, coalesce(k.end_time, k.start_time + interval '60 minutes') from public.classes k
   where k.blocks_privates and k.start_time is not null and k.day = extract(isodow from p_date)::int - 1
     and not (k.off_from is not null and p_date between k.off_from and coalesce(k.off_to, k.off_from))
$$;
