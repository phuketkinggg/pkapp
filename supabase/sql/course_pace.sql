-- How a member takes a course (feature course_pace, on unless switched off): lessons drip one by one on their days (the way we
-- recommend, for example one lesson every other day) or all open at once. The member chooses when they start the course and can
-- change it. A lesson that opened stays open for good. A lesson with a fixed date (open_on) still waits for its date.

create table if not exists public.course_pace (
  customer_id uuid not null references public.customers (id) on delete cascade,
  course_id uuid not null references public.courses (id) on delete cascade,
  pace text not null check (pace in ('drip','all')),
  updated_at timestamptz not null default now(),
  primary key (customer_id, course_id)
);
alter table public.course_pace enable row level security;
revoke all on public.course_pace from public, anon, authenticated;

create or replace function private.course_all_now(p_course uuid, p_customer uuid) returns boolean language sql stable security definer set search_path to '' as $f$
  select private.feature('course_pace', true) and exists (select 1 from public.course_pace p where p.course_id = p_course and p.customer_id = p_customer and p.pace = 'all')
$f$;

create or replace function public.course_pace_set(p_course uuid, p_pace text) returns void language plpgsql security definer set search_path to '' as $f$
declare cid uuid := private.customer_id();
begin
  if not private.feature('course_pace', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if cid is null then raise exception 'Sign in first.'; end if;
  if p_pace not in ('drip','all') then raise exception 'Choose one lesson at a time or all lessons now.'; end if;
  if not private.course_open(p_course, cid) then raise exception 'This course is not open for you yet.'; end if;
  insert into public.course_pace (customer_id, course_id, pace) values (cid, p_course, p_pace)
    on conflict (customer_id, course_id) do update set pace = excluded.pace, updated_at = now();
end $f$;
revoke all on function public.course_pace_set(uuid, text) from public, anon;
grant execute on function public.course_pace_set(uuid, text) to authenticated;

-- lessons: the day they open is skipped when the member chose all at once
do $p$
declare d text; n text;
begin
  if to_regprocedure('private.lesson_opens(public.course_lessons, uuid)') is null then raise notice 'no courses here, skipped'; return; end if;
  d := pg_get_functiondef('private.lesson_opens(public.course_lessons, uuid)'::regprocedure);
  if position('course_all_now' in d) = 0 then
    n := replace(d, $x$coalesce(case when l.open_day is not null then$x$, $x$coalesce(case when l.open_day is not null and not private.course_all_now(l.course_id, p_customer) then$x$);
    if n = d then raise notice 'lesson_opens: older version, skipped'; else execute n;
      if position('course_all_now' in pg_get_functiondef('private.lesson_opens(public.course_lessons, uuid)'::regprocedure)) = 0 then raise exception 'lesson_opens patch did not apply'; end if; end if;
  end if;
  -- the course tells the app which way the member chose
  if to_regprocedure('public.course_view(uuid)') is not null then
    d := pg_get_functiondef('public.course_view(uuid)'::regprocedure);
    if position('course_pace' in d) = 0 then
      n := replace(d, $x$'open', op,$x$, $x$'open', op, 'pace', (select p.pace from public.course_pace p where p.course_id = c.id and p.customer_id = cid), 'pace_on', private.feature('course_pace', true),$x$);
      if n = d then raise notice 'course_view: older version, skipped'; else execute n;
        if position('course_pace' in pg_get_functiondef('public.course_view(uuid)'::regprocedure)) = 0 then raise exception 'course_view patch did not apply'; end if; end if;
    end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
