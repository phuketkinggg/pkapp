delete from mf.template where name like 'course_pace:%';
insert into mf.template (ord, phase, kind, name, sql) values (303001, 3, 'patch', 'course_pace:303001', $TPL$create table if not exists __P__.course_pace (
  customer_id uuid not null references __P__.customers (id) on delete cascade,
  course_id uuid not null references __P__.courses (id) on delete cascade,
  pace text not null check (pace in ('drip','all')),
  updated_at timestamptz not null default now(),
  primary key (customer_id, course_id)
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303002, 3, 'patch', 'course_pace:303002', $TPL$alter table __P__.course_pace enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197101, 11, 'patch', 'course_pace:1197101', $TPL$revoke all on __P__.course_pace from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403101, 4, 'patch', 'course_pace:403101', $TPL$create or replace function __Q__.course_all_now(p_course uuid, p_customer uuid) returns boolean language sql stable security definer set search_path to '' as $f$
  select __Q__.feature('course_pace', true) and exists (select 1 from __P__.course_pace p where p.course_id = p_course and p.customer_id = p_customer and p.pace = 'all')
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403102, 4, 'patch', 'course_pace:403102', $TPL$create or replace function __P__.course_pace_set(p_course uuid, p_pace text) returns void language plpgsql security definer set search_path to '' as $f$
declare cid uuid := __Q__.customer_id();
begin
  if not __Q__.feature('course_pace', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if cid is null then raise exception 'Sign in first.'; end if;
  if p_pace not in ('drip','all') then raise exception 'Choose one lesson at a time or all lessons now.'; end if;
  if not __Q__.course_open(p_course, cid) then raise exception 'This course is not open for you yet.'; end if;
  insert into __P__.course_pace (customer_id, course_id, pace) values (cid, p_course, p_pace)
    on conflict (customer_id, course_id) do update set pace = excluded.pace, updated_at = now();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197102, 11, 'patch', 'course_pace:1197102', $TPL$revoke all on function __P__.course_pace_set(uuid, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197103, 11, 'patch', 'course_pace:1197103', $TPL$grant execute on function __P__.course_pace_set(uuid, text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001701, 10, 'patch', 'course_pace:1001701', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__Q__.lesson_opens(__P__.course_lessons, uuid)') is null then raise notice 'no courses here, skipped'; return; end if;
  d := pg_get_functiondef('__Q__.lesson_opens(__P__.course_lessons, uuid)'::regprocedure);
  if position('course_all_now' in d) = 0 then
    n := replace(d, $x$coalesce(case when l.open_day is not null then$x$, $x$coalesce(case when l.open_day is not null and not __Q__.course_all_now(l.course_id, p_customer) then$x$);
    if n = d then raise notice 'lesson_opens: older version, skipped'; else execute n;
      if position('course_all_now' in pg_get_functiondef('__Q__.lesson_opens(__P__.course_lessons, uuid)'::regprocedure)) = 0 then raise exception 'lesson_opens patch did not apply'; end if; end if;
  end if;
  -- the course tells the app which way the member chose
  if to_regprocedure('__P__.course_view(uuid)') is not null then
    d := pg_get_functiondef('__P__.course_view(uuid)'::regprocedure);
    if position('course_pace' in d) = 0 then
      n := replace(d, $x$'open', op,$x$, $x$'open', op, 'pace', (select p.pace from __P__.course_pace p where p.course_id = c.id and p.customer_id = cid), 'pace_on', __Q__.feature('course_pace', true),$x$);
      if n = d then raise notice 'course_view: older version, skipped'; else execute n;
        if position('course_pace' in pg_get_functiondef('__P__.course_view(uuid)'::regprocedure)) = 0 then raise exception 'course_view patch did not apply'; end if; end if;
    end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'course_pace:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
