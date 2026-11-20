-- Grading levels (feature grading): classes marked as grading classes count, in hours, towards each level.
-- The levels (name, hours since the last level, minimum months) are in app_settings 'grading' as {"levels":[...]}.
-- A coach or manager awards a level; the hours count again from that day.
alter table public.classes add column if not exists grading boolean not null default false;

create table if not exists public.customer_grades (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  level integer not null check (level >= 0),
  on_day date not null default ((now() at time zone 'Asia/Bangkok')::date),
  by_staff uuid,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists customer_grades_customer on public.customer_grades (customer_id, on_day desc);
alter table public.customer_grades enable row level security;
revoke all on public.customer_grades from public, anon, authenticated;

-- a customer's grading: the levels, their current level, the day they got it, and grading hours since then
create or replace function public.grading_progress(p_customer uuid default null) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare cid uuid; lv jsonb; cur integer; since date; hrs numeric; n integer;
begin
  if not private.feature('grading', false) then return null; end if;
  if p_customer is null then cid := private.customer_id();
  elsif coalesce(private.staff_role(), '') in ('manager', 'admin', 'coach', 'front_desk') then cid := p_customer;
  else raise exception 'Not allowed.'; end if;
  if cid is null then return null; end if;
  select case when s.value ~ '^\s*\{' then (s.value::jsonb)->'levels' end into lv from public.app_settings s where s.key = 'grading';
  if lv is null or jsonb_typeof(lv) <> 'array' then lv := '[]'::jsonb; end if;
  select g.level, g.on_day into cur, since from public.customer_grades g where g.customer_id = cid order by g.on_day desc, g.created_at desc limit 1;
  select coalesce(sum(case when c.end_time > c.start_time then extract(epoch from (c.end_time - c.start_time)) / 3600.0 else 1 end), 0), count(*)
    into hrs, n
    from public.checkins k join public.classes c on c.id = k.class_id
    where k.customer_id = cid and c.grading and (since is null or k.day > since);
  return jsonb_build_object('levels', lv, 'level', cur, 'since', since, 'hours', round(hrs, 1), 'classes', n,
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'level', g.level, 'on', g.on_day, 'note', g.note) order by g.on_day desc, g.created_at desc)
      from public.customer_grades g where g.customer_id = cid), '[]'::jsonb));
end $f$;

-- a coach or manager gives a customer a level (the hours start again from that day)
create or replace function public.grading_award(p_customer uuid, p_level integer, p_note text default null) returns uuid language plpgsql security definer set search_path to '' as $f$
declare lv jsonb; new_id uuid;
begin
  if not private.feature('grading', false) then raise exception 'Grading is not switched on.'; end if;
  if coalesce(private.staff_role(), '') not in ('manager', 'admin', 'coach') then raise exception 'Only a coach or a manager can give a level.'; end if;
  select case when s.value ~ '^\s*\{' then (s.value::jsonb)->'levels' end into lv from public.app_settings s where s.key = 'grading';
  if lv is null or jsonb_typeof(lv) <> 'array' or p_level is null or p_level < 0 or p_level >= jsonb_array_length(lv) then raise exception 'Choose one of the grading levels.'; end if;
  if not exists (select 1 from public.customers where id = p_customer) then raise exception 'Customer not found.'; end if;
  insert into public.customer_grades (customer_id, level, on_day, by_staff, note)
    values (p_customer, p_level, (now() at time zone private.tz())::date, private.my_staff_id(), nullif(btrim(coalesce(p_note, '')), ''))
    returning customer_grades.id into new_id;
  return new_id;
end $f$;

-- a manager takes back a level given by mistake
create or replace function public.grading_undo(p_id uuid) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') not in ('manager', 'admin') then raise exception 'Only a manager can take back a level.'; end if;
  delete from public.customer_grades where id = p_id;
end $f$;

revoke all on function public.grading_progress(uuid), public.grading_award(uuid, integer, text), public.grading_undo(uuid) from public, anon;
grant execute on function public.grading_progress(uuid), public.grading_award(uuid, integer, text), public.grading_undo(uuid) to authenticated;
notify pgrst, 'reload schema';
