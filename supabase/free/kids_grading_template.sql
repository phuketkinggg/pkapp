delete from mf.template where name like 'kids_grading:%';
insert into mf.template (ord, phase, kind, name, sql) values (303601, 3, 'patch', 'kids_grading:303601', $TPL$alter table __P__.classes add column if not exists grading boolean not null default false;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303602, 3, 'patch', 'kids_grading:303602', $TPL$create table if not exists __P__.customer_grades (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references __P__.customers(id) on delete cascade,
  level integer not null check (level >= 0),
  on_day date not null default ((now() at time zone 'Asia/Bangkok')::date),
  by_staff uuid,
  note text,
  created_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002301, 10, 'patch', 'kids_grading:1002301', $TPL$create index if not exists customer_grades_customer on __P__.customer_grades (customer_id, on_day desc);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303603, 3, 'patch', 'kids_grading:303603', $TPL$alter table __P__.customer_grades enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197801, 11, 'patch', 'kids_grading:1197801', $TPL$revoke all on __P__.customer_grades from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403801, 4, 'patch', 'kids_grading:403801', $TPL$create or replace function __P__.grading_progress(p_customer uuid default null) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare cid uuid; lv jsonb; cur integer; since date; hrs numeric; n integer;
begin
  if not __Q__.feature('grading', false) then return null; end if;
  if p_customer is null then cid := __Q__.customer_id();
  elsif coalesce(__Q__.staff_role(), '') in ('manager', 'admin', 'coach', 'front_desk') then cid := p_customer;
  else raise exception 'Not allowed.'; end if;
  if cid is null then return null; end if;
  select case when s.value ~ '^\s*\{' then (s.value::jsonb)->'levels' end into lv from __P__.app_settings s where s.key = 'grading';
  if lv is null or jsonb_typeof(lv) <> 'array' then lv := '[]'::jsonb; end if;
  select g.level, g.on_day into cur, since from __P__.customer_grades g where g.customer_id = cid order by g.on_day desc, g.created_at desc limit 1;
  select coalesce(sum(case when c.end_time > c.start_time then extract(epoch from (c.end_time - c.start_time)) / 3600.0 else 1 end), 0), count(*)
    into hrs, n
    from __P__.checkins k join __P__.classes c on c.id = k.class_id
    where k.customer_id = cid and c.grading and (since is null or k.day > since);
  return jsonb_build_object('levels', lv, 'level', cur, 'since', since, 'hours', round(hrs, 1), 'classes', n,
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'level', g.level, 'on', g.on_day, 'note', g.note) order by g.on_day desc, g.created_at desc)
      from __P__.customer_grades g where g.customer_id = cid), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403802, 4, 'patch', 'kids_grading:403802', $TPL$create or replace function __P__.grading_award(p_customer uuid, p_level integer, p_note text default null) returns uuid language plpgsql security definer set search_path to '' as $f$
declare lv jsonb; id uuid;
begin
  if not __Q__.feature('grading', false) then raise exception 'Grading is not switched on.'; end if;
  if coalesce(__Q__.staff_role(), '') not in ('manager', 'admin', 'coach') then raise exception 'Only a coach or a manager can give a level.'; end if;
  select case when s.value ~ '^\s*\{' then (s.value::jsonb)->'levels' end into lv from __P__.app_settings s where s.key = 'grading';
  if lv is null or jsonb_typeof(lv) <> 'array' or p_level is null or p_level < 0 or p_level >= jsonb_array_length(lv) then raise exception 'Choose one of the grading levels.'; end if;
  if not exists (select 1 from __P__.customers where id = p_customer) then raise exception 'Customer not found.'; end if;
  insert into __P__.customer_grades (customer_id, level, on_day, by_staff, note)
    values (p_customer, p_level, (now() at time zone __Q__.tz())::date, __Q__.my_staff_id(), nullif(btrim(coalesce(p_note, '')), ''))
    returning customer_grades.id into id;
  return id;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403803, 4, 'patch', 'kids_grading:403803', $TPL$create or replace function __P__.grading_undo(p_id uuid) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') not in ('manager', 'admin') then raise exception 'Only a manager can take back a level.'; end if;
  delete from __P__.customer_grades where id = p_id;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197802, 11, 'patch', 'kids_grading:1197802', $TPL$revoke all on function __P__.grading_progress(uuid), __P__.grading_award(uuid, integer, text), __P__.grading_undo(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197803, 11, 'patch', 'kids_grading:1197803', $TPL$grant execute on function __P__.grading_progress(uuid), __P__.grading_award(uuid, integer, text), __P__.grading_undo(uuid) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'kids_grading:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
