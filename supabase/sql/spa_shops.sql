-- Massage Mate: several shops (sites or brands with their own income) in one business, each with its own treatments,
-- rooms that belong to one or more shops (grouped by building), therapists who work at some shops only,
-- and commission levels (#1, #2, ...) with a percent each. Runs after spa_mode.sql. Additive: the gym app ignores all of it.

create table if not exists public.spa_shops (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now());
alter table public.spa_shops enable row level security;
revoke all on public.spa_shops from anon, authenticated;
drop policy if exists spa_shops_read on public.spa_shops;
create policy spa_shops_read on public.spa_shops for select to authenticated using (true);
grant select on public.spa_shops to authenticated;

alter table public.spa_beds add column if not exists building text check (char_length(building) <= 60);
alter table public.spa_beds add column if not exists shop_ids uuid[] not null default '{}';      -- empty = every shop
alter table public.spa_services add column if not exists shop_ids uuid[] not null default '{}';  -- empty = every shop
alter table public.privates add column if not exists shop_id uuid references public.spa_shops(id) on delete set null;
alter table public.staff add column if not exists shop_ids uuid[] not null default '{}';         -- empty = every shop
alter table public.staff add column if not exists pay_level int check (pay_level between 1 and 20);

-- commission levels: app_settings 'spa_levels' = [{"level":1,"name":"#1","pct":30}, ...]
create or replace function private.spa_levels() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select case when value ~ '^\s*\[' then value::jsonb end from public.app_settings where key = 'spa_levels'), '[]'::jsonb)
$$;

-- therapists free for a treatment (now also: works at that shop)
drop function if exists private.spa_free_staff(uuid, date, time, uuid);
create or replace function private.spa_free_staff(p_service uuid, d date, t time, p_except uuid default null, p_shop uuid default null)
returns uuid[] language plpgsql stable security definer set search_path to '' as $$
declare sv public.spa_services; out uuid[] := '{}'; s record; dow int := extract(isodow from d)::int;
begin
  select * into sv from public.spa_services where id = p_service;
  for s in select st.* from public.staff st where st.active and (st.role = 'coach' or st.also_coach)
      and (cardinality(sv.staff_ids) = 0 or st.id = any(sv.staff_ids))
      and (p_shop is null or cardinality(st.shop_ids) = 0 or p_shop = any(st.shop_ids))
      and (st.work_days is null or cardinality(st.work_days) = 0 or (dow - 1) = any(st.work_days))
      and (st.work_start is null or (t >= st.work_start and t + make_interval(mins => sv.minutes) <= st.work_end))
      and not exists (select 1 from public.holidays h where h.staff_id = st.id and h.status = 'approved' and d between h.from_date and h.to_date)
    order by st.name loop
    if not exists (select 1 from private.coach_busy(s.id, d, p_except) x where t < x.b_to and t + make_interval(mins => sv.minutes) > x.b_from) then out := out || s.id; end if;
  end loop;
  return out;
end $$;

-- the shop for a treatment: the one asked for (it must offer it), else the treatment's first shop
create or replace function private.spa_pick_shop(p_service uuid, p_shop uuid) returns uuid language plpgsql stable security definer set search_path to '' as $$
declare sv public.spa_services;
begin
  select * into sv from public.spa_services where id = p_service;
  if p_shop is not null then
    if cardinality(sv.shop_ids) > 0 and not (p_shop = any(sv.shop_ids)) then raise exception 'That shop does not offer this treatment.'; end if;
    return p_shop;
  end if;
  if cardinality(sv.shop_ids) > 0 then return sv.shop_ids[1]; end if;
  return (select id from public.spa_shops where active order by sort, name limit 1);
end $$;

-- a free room of the right type that belongs to the shop
create or replace function private.spa_find_bed(p_service uuid, p_shop uuid, d date, t time) returns uuid language sql stable security definer set search_path to '' as $$
  select b.id from public.spa_beds b, public.spa_services sv
   where sv.id = p_service and b.active and (b.kind = sv.bed_kind)
     and (p_shop is null or cardinality(b.shop_ids) = 0 or p_shop = any(b.shop_ids))
     and private.spa_bed_free(b.id, d, t, sv.minutes)
   order by b.sort, b.name limit 1
$$;

-- the board: shops, rooms with building and shops, treatments with shops, staff with shops and level, the levels
create or replace function public.spa_board(p_date date default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare d date := coalesce(p_date, private.bkk_today()); role text := private.staff_role(); dow int := extract(isodow from coalesce(p_date, private.bkk_today()))::int;
  nowt time := (now() at time zone 'Asia/Bangkok')::time;
begin
  if role is null then raise exception 'Not allowed.'; end if;
  return jsonb_build_object('date', d, 'now', to_char(nowt,'HH24:MI'), 'levels', private.spa_levels(),
    'shops', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'active', s.active, 'sort', s.sort) order by s.sort, s.name), '[]'::jsonb) from public.spa_shops s where s.active or role = 'manager'),
    'beds', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'kind', b.kind, 'department', b.department, 'building', b.building, 'shop_ids', b.shop_ids, 'active', b.active, 'sort', b.sort) order by b.sort, b.name), '[]'::jsonb) from public.spa_beds b where b.active or role = 'manager'),
    'services', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'department', s.department, 'minutes', s.minutes, 'price', s.price_thb, 'bed_kind', s.bed_kind, 'people', s.people,
                   'staff_ids', s.staff_ids, 'shop_ids', s.shop_ids, 'description', s.description, 'active', s.active, 'sort', s.sort) order by s.sort, s.name), '[]'::jsonb) from public.spa_services s where s.active or role = 'manager'),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name, 'start', to_char(st.work_start,'HH24:MI'), 'end', to_char(st.work_end,'HH24:MI'),
                   'working', (st.work_days is null or cardinality(st.work_days) = 0 or (dow - 1) = any(st.work_days)) and not exists (select 1 from public.holidays h where h.staff_id = st.id and h.status = 'approved' and d between h.from_date and h.to_date),
                   'pct', coalesce(st.commission_pct, 50), 'level', st.pay_level, 'shop_ids', st.shop_ids,
                   'done_today', (select count(*) from public.privates x where x.coach_id = st.id and x.date = d and x.status in ('confirmed','done')),
                   'last_end', (select to_char(max(x.start_time + make_interval(mins => coalesce(x.minutes,60))),'HH24:MI') from public.privates x where x.coach_id = st.id and x.date = d and x.status in ('confirmed','done') and x.start_time <= nowt)) order by st.name), '[]'::jsonb)
              from public.staff st where st.active and (st.role = 'coach' or st.also_coach)),
    'appts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'time', to_char(x.start_time,'HH24:MI'), 'minutes', coalesce(x.minutes,60), 'status', x.status,
                   'staff_id', x.coach_id, 'bed_id', x.bed_id, 'service_id', x.service_id, 'shop_id', x.shop_id, 'service', coalesce(sv.name, 'Treatment'), 'price', x.price_thb, 'paid', x.paid,
                   'customer_id', x.customer_id, 'who', coalesce(c.name, x.guest_name, 'Guest'), 'phone', c.phone, 'note', x.notes, 'walk_in', x.walk_in,
                   'started', x.arrived_at is not null, 'requested', x.any_coach = false) order by x.start_time), '[]'::jsonb)
              from public.privates x left join public.customers c on c.id = x.customer_id left join public.spa_services sv on sv.id = x.service_id
              where x.date = d and x.status in ('requested','confirmed','done') and (x.service_id is not null or x.bed_id is not null)),
    'takings', (select coalesce(sum(x.price_thb), 0) from public.privates x where x.date = d and x.status = 'done' and x.service_id is not null));
end $$;

-- book: as before, plus the shop
create or replace function public.spa_book(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare role text := private.staff_role(); sv public.spa_services; d date; t time; cid uuid; who uuid; bed uuid; free uuid[]; v uuid; pct numeric; nm text; shop uuid;
begin
  if role is null and private.customer_id() is null then raise exception 'Sign in first.'; end if;
  if role is not null and role not in ('manager','admin','front_desk') then raise exception 'Only the front desk or a manager can book.'; end if;
  select * into sv from public.spa_services where id = nullif(p->>'service_id','')::uuid and active;
  if sv.id is null then raise exception 'Choose a treatment.'; end if;
  if sv.price_thb <= 0 then raise exception 'This treatment has no price yet. Set it in Setup first.'; end if;
  shop := private.spa_pick_shop(sv.id, nullif(p->>'shop_id','')::uuid);
  d := coalesce(nullif(p->>'date','')::date, private.bkk_today());
  begin t := (p->>'time')::time; exception when others then raise exception 'Choose a time.'; end;
  if t is null then raise exception 'Choose a time.'; end if;
  if d < private.bkk_today() and coalesce(role,'') <> 'manager' then raise exception 'Only a manager can add a booking on a past date.'; end if;
  if role is null and (d > private.bkk_today() + 60 or (d = private.bkk_today() and t < (now() at time zone 'Asia/Bangkok')::time)) then raise exception 'Choose a time from now up to 60 days ahead.'; end if;
  cid := case when role is null then private.customer_id() else nullif(p->>'customer_id','')::uuid end;
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
  free := private.spa_free_staff(sv.id, d, t, null, shop);
  who := nullif(p->>'staff_id','')::uuid;
  if who is not null and not (who = any(free)) then raise exception 'That therapist is not free then. Choose another time or "next free".'; end if;
  if who is null then who := private.spa_next_staff(free, d); end if;
  if who is null then raise exception 'No therapist is free for that treatment then. Try another time.'; end if;
  bed := nullif(p->>'bed_id','')::uuid;
  if bed is not null and not private.spa_bed_free(bed, d, t, sv.minutes) then raise exception 'That room is taken then.'; end if;
  if bed is null then bed := private.spa_find_bed(sv.id, shop, d, t); end if;
  if bed is null then raise exception 'No room is free for that treatment then. Try another time.'; end if;
  select coalesce(commission_pct, 50) into pct from public.staff where id = who;
  insert into public.privates (customer_id, coach_id, date, start_time, minutes, price_thb, coach_pct, status, paid, notes, any_coach, service_id, bed_id, shop_id, walk_in, arrived_at, arrived_by)
    values (cid, who, d, t, sv.minutes, sv.price_thb, pct, 'confirmed', false, nullif(left(btrim(coalesce(p->>'note','')), 300), ''),
      nullif(p->>'staff_id','') is null, sv.id, bed, shop, role is not null and coalesce((p->>'walk_in')::boolean, false),
      case when role is not null and coalesce((p->>'walk_in')::boolean, false) then now() end, case when role is not null and coalesce((p->>'walk_in')::boolean, false) then 'spa' end)
    returning id into v;
  return jsonb_build_object('id', v, 'staff', (select name from public.staff where id = who), 'bed', (select name from public.spa_beds where id = bed),
    'shop', (select name from public.spa_shops where id = shop), 'time', to_char(t,'HH24:MI'));
end $$;

-- free times, now per shop
drop function if exists public.spa_times(uuid, date, uuid);
create or replace function public.spa_times(p_service uuid, p_date date, p_staff uuid default null, p_shop uuid default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare sv public.spa_services; t time := '09:00'; out jsonb := '[]'::jsonb; f uuid[]; nowt time := (now() at time zone 'Asia/Bangkok')::time; shop uuid;
begin
  if private.staff_role() is null and private.customer_id() is null then raise exception 'Sign in first.'; end if;
  select * into sv from public.spa_services where id = p_service and active;
  if sv.id is null then return out; end if;
  shop := private.spa_pick_shop(sv.id, p_shop);
  while t <= time '22:00' - make_interval(mins => sv.minutes) loop
    if p_date > private.bkk_today() or t >= nowt then
      f := private.spa_free_staff(sv.id, p_date, t, null, shop);
      if p_staff is not null then f := array(select x from unnest(f) x where x = p_staff); end if;
      if cardinality(f) > 0 and private.spa_find_bed(sv.id, shop, p_date, t) is not null then out := out || to_jsonb(to_char(t, 'HH24:MI')); end if;
    end if;
    t := t + interval '15 minutes';
  end loop;
  return out;
end $$;

-- saving one treatment / room (now with shops and building)
create or replace function public.spa_service_save(p jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid; ids uuid[]; shops uuid[];
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the treatment menu.'; end if;
  if char_length(btrim(coalesce(p->>'name',''))) < 1 then raise exception 'Give the treatment a name.'; end if;
  select coalesce(array_agg(x::uuid), '{}') into ids from jsonb_array_elements_text(coalesce(p->'staff_ids','[]'::jsonb)) x;
  select coalesce(array_agg(x::uuid), '{}') into shops from jsonb_array_elements_text(coalesce(p->'shop_ids','[]'::jsonb)) x;
  if v is null then
    insert into public.spa_services (name, department, minutes, price_thb, bed_kind, people, staff_ids, shop_ids, description, sort, active)
    values (btrim(p->>'name'), coalesce(nullif(btrim(p->>'department'),''),'Massage'), coalesce((p->>'minutes')::int,60), coalesce((p->>'price')::int,0), coalesce(nullif(p->>'bed_kind',''),'bed'),
      coalesce((p->>'people')::int,1), ids, shops, nullif(btrim(coalesce(p->>'description','')),''), coalesce((p->>'sort')::int,0), coalesce((p->>'active')::boolean,true)) returning id into v;
  else
    update public.spa_services set name = btrim(p->>'name'), department = coalesce(nullif(btrim(p->>'department'),''),'Massage'), minutes = coalesce((p->>'minutes')::int,60), price_thb = coalesce((p->>'price')::int,0),
      bed_kind = coalesce(nullif(p->>'bed_kind',''),'bed'), people = coalesce((p->>'people')::int,1), staff_ids = ids, shop_ids = shops, description = nullif(btrim(coalesce(p->>'description','')),''),
      sort = coalesce((p->>'sort')::int,0), active = coalesce((p->>'active')::boolean,true) where id = v;
  end if;
  return v;
end $$;

create or replace function public.spa_bed_save(p jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid; shops uuid[];
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the rooms.'; end if;
  if char_length(btrim(coalesce(p->>'name',''))) < 1 then raise exception 'Give the room a name.'; end if;
  select coalesce(array_agg(x::uuid), '{}') into shops from jsonb_array_elements_text(coalesce(p->'shop_ids','[]'::jsonb)) x;
  if v is null then
    insert into public.spa_beds (name, kind, department, building, shop_ids, sort, active) values (btrim(p->>'name'), coalesce(nullif(p->>'kind',''),'bed'), coalesce(nullif(btrim(p->>'department'),''),'Massage'),
      nullif(btrim(coalesce(p->>'building','')),''), shops, coalesce((p->>'sort')::int,0), coalesce((p->>'active')::boolean,true)) returning id into v;
  else
    update public.spa_beds set name = btrim(p->>'name'), kind = coalesce(nullif(p->>'kind',''),'bed'), department = coalesce(nullif(btrim(p->>'department'),''),'Massage'),
      building = nullif(btrim(coalesce(p->>'building','')),''), shop_ids = shops, sort = coalesce((p->>'sort')::int,0), active = coalesce((p->>'active')::boolean,true) where id = v;
  end if;
  return v;
end $$;

create or replace function public.spa_shop_save(p jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid;
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the shops.'; end if;
  if char_length(btrim(coalesce(p->>'name',''))) < 1 then raise exception 'Give the shop a name.'; end if;
  if v is null then insert into public.spa_shops (name, sort, active) values (btrim(p->>'name'), coalesce((p->>'sort')::int,0), coalesce((p->>'active')::boolean,true)) returning id into v;
  else update public.spa_shops set name = btrim(p->>'name'), sort = coalesce((p->>'sort')::int,0), active = coalesce((p->>'active')::boolean,true) where id = v; end if;
  return v;
end $$;

-- a therapist's shops and commission level (the level's percent becomes their commission)
create or replace function public.spa_staff_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare shops uuid[]; lv int := nullif(p->>'level','')::int; pct numeric;
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  select coalesce(array_agg(x::uuid), '{}') into shops from jsonb_array_elements_text(coalesce(p->'shop_ids','[]'::jsonb)) x;
  select (e->>'pct')::numeric into pct from jsonb_array_elements(private.spa_levels()) e where (e->>'level')::int = lv;
  update public.staff set shop_ids = shops, pay_level = lv, commission_pct = coalesce(pct, commission_pct) where id = (p->>'id')::uuid;
  return jsonb_build_object('ok', true, 'pct', pct);
end $$;

-- commission levels: [{name, pct}] in order; staff on each level get its percent
create or replace function public.spa_levels_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare e jsonb; i int := 0; out jsonb := '[]'::jsonb;
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change commission levels.'; end if;
  for e in select x from jsonb_array_elements(coalesce(p,'[]'::jsonb)) x loop
    if nullif(btrim(coalesce(e->>'name','')),'') is null then continue; end if;
    if coalesce((e->>'pct')::numeric, -1) < 0 or (e->>'pct')::numeric > 100 then raise exception 'Each level needs a percent from 0 to 100.'; end if;
    i := i + 1; out := out || jsonb_build_array(jsonb_build_object('level', i, 'name', left(btrim(e->>'name'), 30), 'pct', (e->>'pct')::numeric));
    update public.staff set commission_pct = (e->>'pct')::numeric where pay_level = i;
  end loop;
  insert into public.app_settings (key, value) values ('spa_levels', out::text) on conflict (key) do update set value = excluded.value;
  update public.staff set pay_level = null where pay_level > i;
  return out;
end $$;

-- quick setup: paste lists. {shops:[name], rooms:[{name, building, kind, shops:[name]}], treatments:[{name, minutes, price, kind, department, shops:[name]}]}
-- matched by name (no duplicates); a treatment or room named again gets the new shops added
create or replace function public.spa_setup(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare e jsonb; nm text; sid uuid; shops uuid[]; n_shop int := 0; n_room int := 0; n_tr int := 0; mx int;
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can set up the spa.'; end if;
  select coalesce(max(sort),0) into mx from public.spa_shops;
  for nm in select btrim(x) from jsonb_array_elements_text(coalesce(p->'shops','[]'::jsonb)) x loop
    if nm = '' or exists (select 1 from public.spa_shops where lower(name) = lower(nm)) then continue; end if;
    mx := mx + 1; insert into public.spa_shops (name, sort) values (left(nm,60), mx); n_shop := n_shop + 1;
  end loop;
  select coalesce(max(sort),0) into mx from public.spa_beds;
  for e in select x from jsonb_array_elements(coalesce(p->'rooms','[]'::jsonb)) x loop
    nm := btrim(coalesce(e->>'name','')); if nm = '' then continue; end if;
    select coalesce(array_agg(s.id), '{}') into shops from public.spa_shops s where lower(s.name) in (select lower(btrim(y)) from jsonb_array_elements_text(coalesce(e->'shops','[]'::jsonb)) y);
    select id into sid from public.spa_beds where lower(name) = lower(left(nm,40)) and coalesce(lower(building),'') = coalesce(lower(nullif(btrim(e->>'building'),'')),'');
    if sid is null then
      mx := mx + 1;
      insert into public.spa_beds (name, building, kind, department, shop_ids, sort) values (left(nm,40), nullif(btrim(coalesce(e->>'building','')),''), coalesce(nullif(e->>'kind',''),'bed'),
        coalesce(nullif(btrim(e->>'department'),''),'Massage'), shops, mx);
      n_room := n_room + 1;
    else update public.spa_beds set shop_ids = (select coalesce(array_agg(distinct z), '{}') from unnest(shop_ids || shops) z) where id = sid; end if;
  end loop;
  select coalesce(max(sort),0) into mx from public.spa_services;
  for e in select x from jsonb_array_elements(coalesce(p->'treatments','[]'::jsonb)) x loop
    nm := btrim(coalesce(e->>'name','')); if nm = '' then continue; end if;
    select coalesce(array_agg(s.id), '{}') into shops from public.spa_shops s where lower(s.name) in (select lower(btrim(y)) from jsonb_array_elements_text(coalesce(e->'shops','[]'::jsonb)) y);
    select id into sid from public.spa_services where lower(name) = lower(left(nm,80));
    if sid is null then
      mx := mx + 1;
      insert into public.spa_services (name, department, minutes, price_thb, bed_kind, shop_ids, sort) values (left(nm,80), coalesce(nullif(btrim(e->>'department'),''),'Massage'),
        least(greatest(coalesce(nullif(e->>'minutes','')::int,60),10),360), greatest(coalesce(nullif(e->>'price','')::int,0),0), coalesce(nullif(e->>'kind',''),'bed'), shops, mx);
      n_tr := n_tr + 1;
    else update public.spa_services set shop_ids = (select coalesce(array_agg(distinct z), '{}') from unnest(shop_ids || shops) z),
      minutes = coalesce(nullif(e->>'minutes','')::int, minutes), price_thb = coalesce(nullif(e->>'price','')::int, price_thb) where id = sid; end if;
  end loop;
  return jsonb_build_object('shops', n_shop, 'rooms', n_room, 'treatments', n_tr);
end $$;

revoke all on function private.spa_levels() from public, anon, authenticated;
revoke all on function private.spa_free_staff(uuid, date, time, uuid, uuid) from public, anon, authenticated;
revoke all on function private.spa_pick_shop(uuid, uuid) from public, anon, authenticated;
revoke all on function private.spa_find_bed(uuid, uuid, date, time) from public, anon, authenticated;
revoke all on function public.spa_times(uuid, date, uuid, uuid) from public, anon;
revoke all on function public.spa_shop_save(jsonb) from public, anon;
revoke all on function public.spa_staff_save(jsonb) from public, anon;
revoke all on function public.spa_levels_save(jsonb) from public, anon;
revoke all on function public.spa_setup(jsonb) from public, anon;
grant execute on function public.spa_times(uuid, date, uuid, uuid) to authenticated;
grant execute on function public.spa_shop_save(jsonb) to authenticated;
grant execute on function public.spa_staff_save(jsonb) to authenticated;
grant execute on function public.spa_levels_save(jsonb) to authenticated;
grant execute on function public.spa_setup(jsonb) to authenticated;
