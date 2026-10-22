-- Pangea wellness app (pangea/index.html): membership level, health numbers, blood tests, the yearly "service" at a Pangea location,
-- and habits members can add themselves. Everything goes through the functions below (no direct table access).

alter table public.customers add column if not exists pangea_level text not null default 'app';
do $$ begin
  alter table public.customers add constraint customers_pangea_level_chk check (pangea_level in ('app','coach','pangea'));
exception when duplicate_object then null; end $$;

create table if not exists public.pangea_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  place text not null default '',
  focus text not null default '',
  blurb text not null default '',
  status text not null default 'soon' check (status in ('open','soon')),
  sort int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.pangea_locations enable row level security;

create table if not exists public.pangea_service (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  location_id uuid not null references public.pangea_locations(id) on delete cascade,
  year int not null check (year between 2025 and 2100),
  month int check (month between 1 and 12),
  note text not null default '',
  created_at timestamptz not null default now(),
  unique (customer_id, year)
);
alter table public.pangea_service enable row level security;

create table if not exists public.health_marks (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  kind text not null,
  value numeric not null default 0,
  value2 numeric,
  at timestamptz not null default now(),
  note text not null default '',
  path text,
  by_staff uuid references public.staff(id) on delete set null,
  removed boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists health_marks_cust on public.health_marks (customer_id, kind, at desc);
alter table public.health_marks enable row level security;

insert into public.pangea_locations (name, place, focus, blurb, status, sort)
select * from (values
  ('Pangea Phuket King','Kathu, Phuket, Thailand','Muay Thai and fitness','Muay Thai, strength and conditioning, spa, lakeside rooms and a clean food cafe. The sport is the vessel, the journey is yours.','open',1),
  ('Pangea Tennis','Mauritius','Tennis','Coming soon.','soon',2),
  ('Pangea Golf','To be announced','Golf','Coming soon.','soon',3),
  ('Pangea Tranquility','To be announced','Rest, breath and recovery','Coming soon.','soon',4),
  ('Pangea Longevity','To be announced','Anti-aging and longevity','Coming soon.','soon',5),
  ('Pangea Fishing','To be announced','Fishing and the outdoors','Coming soon.','soon',6)
) v(name, place, focus, blurb, status, sort)
where not exists (select 1 from public.pangea_locations);

-- which health numbers are allowed, with sane limits
create or replace function private.health_kind_ok(k text, v numeric, v2 numeric) returns text
language plpgsql immutable set search_path to '' as $$
begin
  case k
    when 'bp' then if v between 60 and 260 and v2 between 30 and 160 then return null; end if; return 'Type blood pressure like 120 over 80.';
    when 'rhr' then if v between 25 and 200 then return null; end if; return 'Resting heart rate is beats a minute, for example 62.';
    when 'sleep' then if v between 0 and 16 then return null; end if; return 'Sleep is hours, for example 7.5';
    when 'steps' then if v between 0 and 100000 then return null; end if; return 'Type the number of steps.';
    when 'waist' then if v between 40 and 200 then return null; end if; return 'Waist is in cm.';
    when 'bodyfat' then if v between 2 and 70 then return null; end if; return 'Body fat is a percent, for example 18.';
    when 'energy','mood','stress' then if v between 1 and 5 then return null; end if; return 'Pick 1 to 5.';
    when 'glucose' then if v between 1 and 35 then return null; end if; return 'Glucose is mmol/L, for example 5.2';
    when 'hba1c' then if v between 3 and 20 then return null; end if; return 'HbA1c is a percent, for example 5.4';
    when 'chol','ldl','hdl','trig' then if v between 0.1 and 20 then return null; end if; return 'Cholesterol numbers are mmol/L.';
    when 'vitd' then if v between 1 and 250 then return null; end if; return 'Vitamin D is ng/mL.';
    when 'crp' then if v between 0 and 300 then return null; end if; return 'CRP is mg/L.';
    when 'testo' then if v between 0 and 100 then return null; end if; return 'Testosterone is nmol/L.';
    when 'ferritin' then if v between 1 and 3000 then return null; end if; return 'Ferritin is ng/mL.';
    when 'bloods' then return null;
    else return 'Pick what you are logging.';
  end case;
end $$;

-- everything the Pangea app shows for the signed in member
create or replace function public.pangea_home() returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare v uuid := private.customer_id(); c public.customers;
begin
  if v is null then raise exception 'Sign in first.'; end if;
  select * into c from public.customers where id = v;
  return jsonb_build_object(
    'me', jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'level', c.pangea_level),
    'coaching', private.coaching_data(v, false),
    'health', coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'kind',h.kind,'value',h.value,'value2',h.value2,'at',h.at,'note',h.note,'path',h.path,'coach',h.by_staff is not null) order by h.at)
      from public.health_marks h where h.customer_id = v and not h.removed and h.at >= now() - interval '800 days'), '[]'::jsonb),
    'service', coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'year',s.year,'month',s.month,'note',s.note,'location_id',s.location_id,'location',l.name,'place',l.place,'focus',l.focus) order by s.year)
      from public.pangea_service s join public.pangea_locations l on l.id = s.location_id where s.customer_id = v), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(to_jsonb(l) - 'created_at' order by l.sort, l.name) from public.pangea_locations l), '[]'::jsonb),
    'stay', (select jsonb_build_object('check_in', s.check_in, 'check_out', s.check_out, 'room', r.name, 'status', s.status)
      from public.stays s left join public.rooms r on r.id = s.room_id
      where s.customer_id = v and s.status not in ('cancelled') and s.check_out >= private.bkk_today()
      order by s.check_in limit 1)
  );
end $$;

create or replace function public.pangea_health_add(p jsonb) returns uuid
language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'customer_id','')::uuid; k text := coalesce(p->>'kind',''); a numeric := coalesce(nullif(p->>'value','')::numeric, 0);
  b numeric := nullif(p->>'value2','')::numeric; err text; r uuid; v_by uuid := null; pth text := nullif(p->>'path','');
begin
  if v is null or v = private.customer_id() then v := private.customer_id(); if v is null then raise exception 'Sign in first.'; end if;
  elsif private.coach_can(v) then v_by := private.my_staff_id();
  else raise exception 'Not allowed.'; end if;
  err := private.health_kind_ok(k, a, b);
  if err is not null then raise exception '%', err; end if;
  if k = 'bloods' and coalesce(pth,'') !~ ('^' || v::text || '/health/[A-Za-z0-9._-]+$') then raise exception 'Upload the blood test in the app.'; end if;
  if k <> 'bloods' then pth := null; end if;
  insert into public.health_marks (customer_id, kind, value, value2, at, note, path, by_staff)
  values (v, k, round(a, 2), case when k = 'bp' then round(b) end, least(now(), coalesce(nullif(p->>'at','')::timestamptz, now())), left(coalesce(p->>'note',''), 300), pth, v_by)
  returning id into r;
  return r;
end $$;

create or replace function public.pangea_health_remove(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare v uuid;
begin
  select customer_id into v from public.health_marks where id = p_id and not removed;
  if v is null or not (v = private.customer_id() or private.coach_can(v)) then raise exception 'Not found.'; end if;
  update public.health_marks set removed = true where id = p_id;
end $$;

create or replace function public.pangea_service_save(p jsonb) returns uuid
language plpgsql security definer set search_path to '' as $$
declare v uuid := private.customer_id(); y int := nullif(p->>'year','')::int; m int := nullif(p->>'month','')::int; l uuid := nullif(p->>'location_id','')::uuid; r uuid;
begin
  if v is null then raise exception 'Sign in first.'; end if;
  if y is null or y < extract(year from private.bkk_today())::int or y > extract(year from private.bkk_today())::int + 10 then raise exception 'Pick a year from this year on.'; end if;
  if m is not null and (m < 1 or m > 12) then m := null; end if;
  if not exists (select 1 from public.pangea_locations where id = l) then raise exception 'Pick a location.'; end if;
  insert into public.pangea_service (customer_id, location_id, year, month, note) values (v, l, y, m, left(coalesce(p->>'note',''), 300))
  on conflict (customer_id, year) do update set location_id = excluded.location_id, month = excluded.month, note = excluded.note
  returning id into r;
  if not exists (select 1 from public.notices n where n.customer_id = v and n.kind = 'pangea_service' and n.created_at > now() - interval '1 day') then
    insert into public.notices (kind, customer_id, title, detail)
    select 'pangea_service', v, 'Pangea plan: ' || c.name, 'Planned ' || y || coalesce(' ' || to_char(make_date(y, m, 1), 'Mon'), '') || ' at ' || (select name from public.pangea_locations where id = l) || '.'
    from public.customers c where c.id = v;
  end if;
  return r;
end $$;

create or replace function public.pangea_service_remove(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
begin
  delete from public.pangea_service where id = p_id and customer_id = private.customer_id();
end $$;

-- members can add their own habits (coaches still set theirs from the coaching screen)
create or replace function public.pangea_habit_add(p jsonb) returns uuid
language plpgsql security definer set search_path to '' as $$
declare v uuid := private.customer_id(); f text := coalesce(p->>'freq','daily'); d smallint[]; t smallint := greatest(1, least(7, coalesce(nullif(p->>'times','')::smallint, 1))); r uuid;
begin
  if v is null then raise exception 'Sign in first.'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'Give the habit a name.'; end if;
  if (select count(*) from public.habits h where h.customer_id = v and h.stopped_on is null and (h.end_on is null or h.end_on >= private.bkk_today())) >= 15 then
    raise exception 'You have 15 habits going. Stop one before adding another.'; end if;
  if f not in ('daily','days','week') then f := 'daily'; end if;
  select coalesce(array_agg(distinct x::smallint order by x::smallint), '{}') into d
  from jsonb_array_elements_text(case when jsonb_typeof(p->'days') = 'array' then p->'days' else '[]'::jsonb end) x where x ~ '^[1-7]$';
  if f = 'days' and cardinality(d) = 0 then raise exception 'Pick the days.'; end if;
  insert into public.habits (customer_id, name, details, freq, days, times, start_on, links, created_by)
  values (v, left(btrim(p->>'name'), 120), left(coalesce(p->>'details',''), 2000), f, d, t, private.bkk_today(), '[]'::jsonb, null)
  returning id into r;
  return r;
end $$;

create or replace function public.pangea_habit_stop(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
begin
  update public.habits set stopped_on = private.bkk_today(), updated_at = now()
  where id = p_id and customer_id = private.customer_id() and created_by is null and group_member is null;
  if not found then raise exception 'Only habits you added yourself can be stopped here. Ask your coach about the others.'; end if;
end $$;

-- back office: level and health for one client
create or replace function public.pangea_level_set(p_customer uuid, p_level text) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the Pangea level.'; end if;
  if p_level not in ('app','coach','pangea') then raise exception 'Pick app, coach or pangea.'; end if;
  update public.customers set pangea_level = p_level where id = p_customer;
end $$;

create or replace function public.pangea_client(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if not private.coach_can(p_customer) then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'level', (select pangea_level from public.customers where id = p_customer),
    'health', coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'kind',h.kind,'value',h.value,'value2',h.value2,'at',h.at,'note',h.note,'path',h.path) order by h.at desc)
      from public.health_marks h where h.customer_id = p_customer and not h.removed), '[]'::jsonb),
    'service', coalesce((select jsonb_agg(jsonb_build_object('year',s.year,'month',s.month,'location',l.name,'note',s.note) order by s.year)
      from public.pangea_service s join public.pangea_locations l on l.id = s.location_id where s.customer_id = p_customer), '[]'::jsonb));
end $$;

revoke all on function public.pangea_home(), public.pangea_health_add(jsonb), public.pangea_health_remove(uuid), public.pangea_service_save(jsonb),
  public.pangea_service_remove(uuid), public.pangea_habit_add(jsonb), public.pangea_habit_stop(uuid), public.pangea_level_set(uuid, text), public.pangea_client(uuid) from public, anon;
grant execute on function public.pangea_home(), public.pangea_health_add(jsonb), public.pangea_health_remove(uuid), public.pangea_service_save(jsonb),
  public.pangea_service_remove(uuid), public.pangea_habit_add(jsonb), public.pangea_habit_stop(uuid), public.pangea_level_set(uuid, text), public.pangea_client(uuid) to authenticated;

-- members can message a coach they are assigned to, not only coaches they had privates with
do $$ declare d text := pg_get_functiondef('public.chat_start(uuid,uuid,boolean)'::regprocedure); begin
  if position('coach_clients cc where cc.customer_id = me_c' in d) = 0 then
    d := replace(d, 'if p_staff is null or not exists (select 1 from public.privates p where p.customer_id = me_c and p.coach_id = p_staff) then',
      'if p_staff is null or (not exists (select 1 from public.privates p where p.customer_id = me_c and p.coach_id = p_staff) and not exists (select 1 from public.coach_clients cc where cc.customer_id = me_c and cc.staff_id = p_staff)) then');
    execute d;
  end if;
end $$;
