-- Spa and salon mode (Massage Mate). Same database as the gym app; only used when the app runs as a spa.
-- Beds (or chairs, nail desks, couple rooms), a treatment menu with times, and appointments.
-- An appointment is a row in public.privates (the therapist is coach_id), with the treatment and the bed added,
-- so payments, commission, the therapist's "my day", clashes and holidays all work as they do for privates.

create table if not exists public.spa_beds (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  kind text not null default 'bed' check (kind in ('bed','couple','foot','nail','facial','hair','other')),
  department text not null default 'Massage' check (char_length(department) between 1 and 30),
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now());

create table if not exists public.spa_services (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  department text not null default 'Massage' check (char_length(department) between 1 and 30),
  minutes int not null default 60 check (minutes between 10 and 360),
  price_thb int not null check (price_thb between 0 and 1000000),
  bed_kind text not null default 'bed' check (bed_kind in ('bed','couple','foot','nail','facial','hair','other')),
  people int not null default 1 check (people between 1 and 2),
  staff_ids uuid[] not null default '{}',          -- empty = every therapist can do it
  description text check (char_length(description) <= 300),
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now());

alter table public.privates add column if not exists service_id uuid references public.spa_services(id) on delete set null;
alter table public.privates add column if not exists bed_id uuid references public.spa_beds(id) on delete set null;
alter table public.privates add column if not exists walk_in boolean not null default false;
create index if not exists privates_bed_day on public.privates (bed_id, date) where bed_id is not null;

alter table public.spa_beds enable row level security;
alter table public.spa_services enable row level security;
revoke all on public.spa_beds from anon, authenticated;
revoke all on public.spa_services from anon, authenticated;
drop policy if exists spa_beds_read on public.spa_beds;
create policy spa_beds_read on public.spa_beds for select to authenticated using (private.staff_role() is not null);
drop policy if exists spa_services_read on public.spa_services;
create policy spa_services_read on public.spa_services for select to authenticated using (true);
grant select on public.spa_beds, public.spa_services to authenticated;

-- is that bed free from t for m minutes on day d (not counting appointment p_except)?
create or replace function private.spa_bed_free(p_bed uuid, d date, t time, m int, p_except uuid default null)
returns boolean language sql stable security definer set search_path to '' as $$
  select not exists (select 1 from public.privates x left join public.spa_beds b on b.id = x.bed_id
    where x.bed_id = p_bed and x.date = d and x.status in ('confirmed','done') and x.id is distinct from p_except
      and x.start_time < t + make_interval(mins => m) and t < x.start_time + make_interval(mins => coalesce(x.minutes, 60)))
$$;

-- therapists who work that day and time, can do the treatment, and are free (holidays and clashes checked)
create or replace function private.spa_free_staff(p_service uuid, d date, t time, p_except uuid default null)
returns uuid[] language plpgsql stable security definer set search_path to '' as $$
declare sv public.spa_services; out uuid[] := '{}'; s record; dow int := extract(isodow from d)::int;
begin
  select * into sv from public.spa_services where id = p_service;
  for s in select st.* from public.staff st where st.active and (st.role = 'coach' or st.also_coach)
      and (cardinality(sv.staff_ids) = 0 or st.id = any(sv.staff_ids))
      and (st.work_days is null or cardinality(st.work_days) = 0 or (dow - 1) = any(st.work_days))
      and (st.work_start is null or (t >= st.work_start and t + make_interval(mins => sv.minutes) <= st.work_end))
      and not exists (select 1 from public.holidays h where h.staff_id = st.id and h.status = 'approved' and d between h.from_date and h.to_date)
    order by st.name loop
    if not exists (select 1 from private.coach_busy(s.id, d, p_except) x where t < x.b_to and t + make_interval(mins => sv.minutes) > x.b_from) then out := out || s.id; end if;
  end loop;
  return out;
end $$;

-- walk-in turn order: the free therapist who has worked least today goes first (then who finished longest ago)
create or replace function private.spa_next_staff(p_free uuid[], d date)
returns uuid language sql stable security definer set search_path to '' as $$
  select f from unnest(p_free) f
  order by (select count(*) from public.privates x where x.coach_id = f and x.date = d and x.status in ('confirmed','done')),
           (select max(x.start_time + make_interval(mins => coalesce(x.minutes,60))) from public.privates x where x.coach_id = f and x.date = d and x.status in ('confirmed','done')) nulls first
  limit 1
$$;

-- the front desk board for a day
create or replace function public.spa_board(p_date date default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare d date := coalesce(p_date, private.bkk_today()); role text := private.staff_role(); dow int := extract(isodow from coalesce(p_date, private.bkk_today()))::int;
begin
  if role is null then raise exception 'Not allowed.'; end if;
  return jsonb_build_object('date', d,
    'beds', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'department', b.department, 'active', b.active) order by b.sort, b.name), '[]'::jsonb) from public.spa_beds b where b.active or role = 'manager'),
    'services', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'department', s.department, 'minutes', s.minutes, 'price', s.price_thb, 'bed_kind', s.bed_kind, 'people', s.people,
                   'staff_ids', s.staff_ids, 'description', s.description, 'active', s.active, 'sort', s.sort) order by s.department, s.sort, s.name), '[]'::jsonb) from public.spa_services s where s.active or role = 'manager'),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name, 'start', to_char(st.work_start,'HH24:MI'), 'end', to_char(st.work_end,'HH24:MI'),
                   'working', (st.work_days is null or cardinality(st.work_days) = 0 or (dow - 1) = any(st.work_days)) and not exists (select 1 from public.holidays h where h.staff_id = st.id and h.status = 'approved' and d between h.from_date and h.to_date),
                   'pct', coalesce(st.commission_pct, 50),
                   'done_today', (select count(*) from public.privates x where x.coach_id = st.id and x.date = d and x.status in ('confirmed','done'))) order by st.name), '[]'::jsonb)
              from public.staff st where st.active and (st.role = 'coach' or st.also_coach)),
    'appts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'time', to_char(x.start_time,'HH24:MI'), 'minutes', coalesce(x.minutes,60), 'status', x.status,
                   'staff_id', x.coach_id, 'bed_id', x.bed_id, 'service_id', x.service_id, 'service', coalesce(sv.name, 'Treatment'), 'price', x.price_thb, 'paid', x.paid,
                   'customer_id', x.customer_id, 'who', coalesce(c.name, x.guest_name, 'Guest'), 'phone', c.phone, 'note', x.notes, 'walk_in', x.walk_in,
                   'started', x.arrived_at is not null, 'requested', x.any_coach = false) order by x.start_time), '[]'::jsonb)
              from public.privates x left join public.customers c on c.id = x.customer_id left join public.spa_services sv on sv.id = x.service_id
              where x.date = d and x.status in ('requested','confirmed','done') and (x.service_id is not null or x.bed_id is not null)),
    'next', private.spa_next_staff(coalesce((select array_agg(st.id) from public.staff st where st.active and (st.role = 'coach' or st.also_coach)
              and not exists (select 1 from public.privates x where x.coach_id = st.id and x.date = d and x.status = 'confirmed' and x.arrived_at is not null
                               and (now() at time zone 'Asia/Bangkok')::time between x.start_time and x.start_time + make_interval(mins => coalesce(x.minutes,60))))), '{}'), d),
    'takings', (select coalesce(sum(x.price_thb), 0) from public.privates x where x.date = d and x.status = 'done' and x.service_id is not null));
end $$;

-- book an appointment (front desk, manager): {customer_id | name + phone, service_id, date, time, staff_id (optional), bed_id (optional), note, walk_in}
create or replace function public.spa_book(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare role text := private.staff_role(); sv public.spa_services; d date; t time; cid uuid; who uuid; bed uuid; free uuid[]; v uuid; pct numeric; nm text;
begin
  if role is null or role not in ('manager','admin','front_desk') then raise exception 'Only the front desk or a manager can book.'; end if;
  select * into sv from public.spa_services where id = nullif(p->>'service_id','')::uuid and active;
  if sv.id is null then raise exception 'Choose a treatment.'; end if;
  d := coalesce(nullif(p->>'date','')::date, private.bkk_today());
  begin t := (p->>'time')::time; exception when others then raise exception 'Choose a time.'; end;
  if t is null then raise exception 'Choose a time.'; end if;
  if d < private.bkk_today() and role <> 'manager' then raise exception 'Only a manager can add a booking on a past date.'; end if;
  -- the customer
  cid := nullif(p->>'customer_id','')::uuid;
  if cid is null then
    nm := btrim(coalesce(p->>'name',''));
    if char_length(nm) < 2 then nm := 'Walk-in guest'; end if;
    if nullif(btrim(coalesce(p->>'phone','')),'') is not null then
      select id into cid from public.customers where regexp_replace(phone,'\D','','g') = regexp_replace(p->>'phone','\D','','g') limit 1;
    end if;
    if cid is null then
      insert into public.customers (name, phone, lead_source) values (left(nm, 80), nullif(left(btrim(coalesce(p->>'phone','')),30),''), case when (p->>'walk_in')::boolean then 'Walk in' else 'Front desk' end) returning id into cid;
    end if;
  end if;
  -- the therapist
  free := private.spa_free_staff(sv.id, d, t, null);
  who := nullif(p->>'staff_id','')::uuid;
  if who is not null and not (who = any(free)) then raise exception 'That therapist is not free then. Choose another time or "next free".'; end if;
  if who is null then who := private.spa_next_staff(free, d); end if;
  if who is null then raise exception 'No therapist is free for that treatment then. Try another time.'; end if;
  -- the bed
  bed := nullif(p->>'bed_id','')::uuid;
  if bed is not null and not private.spa_bed_free(bed, d, t, sv.minutes) then raise exception 'That bed is taken then.'; end if;
  if bed is null then
    select b.id into bed from public.spa_beds b where b.active and b.kind = sv.bed_kind and private.spa_bed_free(b.id, d, t, sv.minutes) order by b.sort, b.name limit 1;
    if bed is null then
      select b.id into bed from public.spa_beds b where b.active and b.department = sv.department and private.spa_bed_free(b.id, d, t, sv.minutes) order by b.sort, b.name limit 1;
    end if;
  end if;
  if bed is null then raise exception 'No % is free then. Try another time.', case sv.bed_kind when 'couple' then 'couple room' when 'foot' then 'foot chair' when 'nail' then 'nail desk' else sv.bed_kind end; end if;
  select coalesce(commission_pct, 50) into pct from public.staff where id = who;
  insert into public.privates (customer_id, coach_id, date, start_time, minutes, price_thb, coach_pct, status, paid, notes, any_coach, service_id, bed_id, walk_in)
    values (cid, who, d, t, sv.minutes, sv.price_thb, pct, 'confirmed', false, nullif(left(btrim(coalesce(p->>'note','')), 300), ''),
      nullif(p->>'staff_id','') is null, sv.id, bed, coalesce((p->>'walk_in')::boolean, false))
    returning id into v;
  return jsonb_build_object('id', v, 'staff', (select name from public.staff where id = who), 'bed', (select name from public.spa_beds where id = bed), 'time', to_char(t,'HH24:MI'));
end $$;

-- start, finish, cancel or no-show an appointment
create or replace function public.spa_step(p_id uuid, p_step text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare role text := private.staff_role(); x public.privates; me uuid := private.my_staff_id();
begin
  if role is null then raise exception 'Not allowed.'; end if;
  select * into x from public.privates where id = p_id;
  if x.id is null then raise exception 'That booking was not found.'; end if;
  if role = 'coach' and x.coach_id is distinct from me then raise exception 'That is not your booking.'; end if;
  if p_step = 'start' then update public.privates set arrived_at = now(), arrived_by = 'spa' where id = p_id;
  elsif p_step = 'unstart' then update public.privates set arrived_at = null, arrived_by = null where id = p_id and status = 'confirmed';
  elsif p_step = 'done' then update public.privates set status = 'done', arrived_at = coalesce(arrived_at, now()) where id = p_id;
  elsif p_step in ('cancel','noshow') then
    if role not in ('manager','admin','front_desk') then raise exception 'Ask the front desk to cancel.'; end if;
    update public.privates set status = 'cancelled', decline_reason = case when p_step = 'noshow' then 'No show' else 'Cancelled at the desk' end where id = p_id;
  else raise exception 'Unknown step.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- the treatment menu and the beds (manager)
create or replace function public.spa_service_save(p jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid; ids uuid[];
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the treatment menu.'; end if;
  select coalesce(array_agg(x::uuid), '{}') into ids from jsonb_array_elements_text(coalesce(p->'staff_ids','[]'::jsonb)) x;
  if v is null then
    insert into public.spa_services (name, department, minutes, price_thb, bed_kind, people, staff_ids, description, sort, active)
    values (btrim(p->>'name'), coalesce(nullif(btrim(p->>'department'),''),'Massage'), (p->>'minutes')::int, (p->>'price')::int, coalesce(nullif(p->>'bed_kind',''),'bed'),
      coalesce((p->>'people')::int,1), ids, nullif(btrim(coalesce(p->>'description','')),''), coalesce((p->>'sort')::int,0), coalesce((p->>'active')::boolean,true)) returning id into v;
  else
    update public.spa_services set name = btrim(p->>'name'), department = coalesce(nullif(btrim(p->>'department'),''),'Massage'), minutes = (p->>'minutes')::int, price_thb = (p->>'price')::int,
      bed_kind = coalesce(nullif(p->>'bed_kind',''),'bed'), people = coalesce((p->>'people')::int,1), staff_ids = ids, description = nullif(btrim(coalesce(p->>'description','')),''),
      sort = coalesce((p->>'sort')::int,0), active = coalesce((p->>'active')::boolean,true) where id = v;
  end if;
  return v;
end $$;

create or replace function public.spa_bed_save(p jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid;
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the beds.'; end if;
  if v is null then
    insert into public.spa_beds (name, kind, department, sort, active) values (btrim(p->>'name'), coalesce(nullif(p->>'kind',''),'bed'), coalesce(nullif(btrim(p->>'department'),''),'Massage'), coalesce((p->>'sort')::int,0), coalesce((p->>'active')::boolean,true)) returning id into v;
  else
    update public.spa_beds set name = btrim(p->>'name'), kind = coalesce(nullif(p->>'kind',''),'bed'), department = coalesce(nullif(btrim(p->>'department'),''),'Massage'), sort = coalesce((p->>'sort')::int,0), active = coalesce((p->>'active')::boolean,true) where id = v;
  end if;
  return v;
end $$;

-- free times for one treatment on one day, in 15 minute steps (front desk booking and the customer app)
create or replace function public.spa_times(p_service uuid, p_date date, p_staff uuid default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare sv public.spa_services; t time := '09:00'; out jsonb := '[]'::jsonb; f uuid[]; nowt time := (now() at time zone 'Asia/Bangkok')::time;
begin
  if private.staff_role() is null and private.customer_id() is null then raise exception 'Sign in first.'; end if;
  select * into sv from public.spa_services where id = p_service and active;
  if sv.id is null then return out; end if;
  while t <= time '22:00' - make_interval(mins => sv.minutes) loop
    if p_date > private.bkk_today() or t >= nowt then
      f := private.spa_free_staff(sv.id, p_date, t, null);
      if p_staff is not null then f := array(select x from unnest(f) x where x = p_staff); end if;
      if cardinality(f) > 0 and exists (select 1 from public.spa_beds b where b.active and (b.kind = sv.bed_kind or b.department = sv.department) and private.spa_bed_free(b.id, p_date, t, sv.minutes)) then
        out := out || to_jsonb(to_char(t, 'HH24:MI'));
      end if;
    end if;
    t := t + interval '15 minutes';
  end loop;
  return out;
end $$;

revoke all on function private.spa_bed_free(uuid, date, time, int, uuid) from public, anon, authenticated;
revoke all on function private.spa_free_staff(uuid, date, time, uuid) from public, anon, authenticated;
revoke all on function private.spa_next_staff(uuid[], date) from public, anon, authenticated;
revoke all on function public.spa_board(date) from public, anon;
revoke all on function public.spa_book(jsonb) from public, anon;
revoke all on function public.spa_step(uuid, text) from public, anon;
revoke all on function public.spa_service_save(jsonb) from public, anon;
revoke all on function public.spa_bed_save(jsonb) from public, anon;
revoke all on function public.spa_times(uuid, date, uuid) from public, anon;
grant execute on function public.spa_board(date) to authenticated;
grant execute on function public.spa_book(jsonb) to authenticated;
grant execute on function public.spa_step(uuid, text) to authenticated;
grant execute on function public.spa_service_save(jsonb) to authenticated;
grant execute on function public.spa_bed_save(jsonb) to authenticated;
grant execute on function public.spa_times(uuid, date, uuid) to authenticated;
