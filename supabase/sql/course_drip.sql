-- Courses: lessons that open later. Each lesson can open a number of days after the student starts the course
-- (open_day, day 1 = the day they start), or on a set date (open_on), or both (the later of the two). Empty = open straight away.
-- The student starts when they get the course (course_access), or, for a course that is free for members, on their first finished lesson.
-- Managers and staff always see every lesson. Free preview lessons are always open.

alter table public.course_lessons add column if not exists open_day integer check (open_day is null or open_day between 1 and 730);
alter table public.course_lessons add column if not exists open_on date;

create or replace function private.course_started(p_course uuid, p_customer uuid) returns timestamptz language sql stable security definer set search_path to '' as $$
  select coalesce(
    (select min(a.created_at) from public.course_access a where a.course_id = p_course and a.customer_id = p_customer),
    (select min(pr.done_at) from public.course_progress pr join public.course_lessons l on l.id = pr.lesson_id where l.course_id = p_course and pr.customer_id = p_customer),
    now())
$$;

-- when the lesson opens for this student (null = open now)
create or replace function private.lesson_opens(l public.course_lessons, p_customer uuid) returns timestamptz language sql stable security definer set search_path to '' as $$
  select case when l.free or coalesce(private.staff_role() is not null, false) then null else
    nullif(greatest(
      coalesce(case when l.open_on is not null then (l.open_on::timestamp at time zone 'Asia/Bangkok') end, '-infinity'::timestamptz),
      coalesce(case when l.open_day is not null then
        ((private.course_started(l.course_id, p_customer) at time zone 'Asia/Bangkok')::date + (l.open_day - 1))::timestamp at time zone 'Asia/Bangkok' end, '-infinity'::timestamptz)),
      '-infinity'::timestamptz) end
$$;
create or replace function private.lesson_released(l public.course_lessons, p_customer uuid) returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce(private.lesson_opens(l, p_customer) <= now(), true)
$$;

-- the member's view of a course: a lesson that has not opened yet shows its name and when it opens, not the video
create or replace function public.course_view(p_course uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare cid uuid := private.customer_id(); c public.courses; op boolean;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  select * into c from public.courses where id = p_course and (status = 'published' or private.staff_role() = 'manager');
  if c.id is null then raise exception 'That course was not found.'; end if;
  op := private.course_open(c.id, cid);
  return jsonb_build_object('id', c.id, 'slug', c.slug, 'title', c.title, 'summary', c.summary, 'about', c.about, 'cover', c.cover_url, 'price', c.price_thb,
    'members_free', c.members_free, 'status', c.status, 'sort', c.sort, 'open', op,
    'lessons', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'title', l.title, 'minutes', l.minutes, 'free', l.free, 'sort', l.sort,
        'open_day', l.open_day, 'open_on', l.open_on,
        'opens', case when op and not l.free and not private.lesson_released(l, cid) then private.lesson_opens(l, cid) end,
        'open', (op and private.lesson_released(l, cid)) or l.free,
        'video', case when (op and private.lesson_released(l, cid)) or l.free then l.video_url end,
        'body', case when (op and private.lesson_released(l, cid)) or l.free then l.body end,
        'files', case when (op and private.lesson_released(l, cid)) or l.free then l.files else '[]'::jsonb end,
        'has_video', l.video_url is not null, 'n_files', jsonb_array_length(l.files),
        'done', exists (select 1 from public.course_progress pr where pr.lesson_id = l.id and pr.customer_id = cid and pr.done)) order by l.sort, l.created_at), '[]'::jsonb)
      from public.course_lessons l where l.course_id = c.id and not l.removed));
end $$;

-- ticking a lesson done: only once it is open
do $$ declare s text;
begin
  s := pg_get_functiondef('public.course_done(uuid,boolean)'::regprocedure);
  if s like '%lesson_released%' then return; end if;
  s := replace(s, 'not (l.free or private.course_open(l.course_id, cid))', 'not (l.free or (private.course_open(l.course_id, cid) and private.lesson_released(l, cid)))');
  if s not like '%lesson_released%' then raise notice 'course_done is a different version here: skipped.'; return; end if;
  execute s;
end $$;

-- saving a lesson keeps when it opens
do $$ declare s text;
begin
  s := pg_get_functiondef('public.course_lesson_save(jsonb)'::regprocedure);
  if s like '%open_day%' then return; end if;
  s := replace(s, 'insert into public.course_lessons (course_id, sort, title, video_url, body, files, free, minutes)',
                  'insert into public.course_lessons (course_id, sort, title, video_url, body, files, free, minutes, open_day, open_on)');
  s := replace(s, $a$coalesce((p->>'free')::boolean, false), nullif(p->>'minutes','')::numeric::int) returning id into lid;$a$,
                  $a$coalesce((p->>'free')::boolean, false), nullif(p->>'minutes','')::numeric::int,
      case when (p->>'open_day') ~ '^[0-9]{1,3}$' and (p->>'open_day')::int between 1 and 730 then (p->>'open_day')::int end,
      case when (p->>'open_on') ~ '^\d{4}-\d{2}-\d{2}$' then (p->>'open_on')::date end) returning id into lid;$a$);
  s := replace(s, $a$minutes = nullif(p->>'minutes','')::numeric::int, sort = coalesce(nullif(p->>'sort','')::int, sort) where id = lid and not removed;$a$,
                  $a$minutes = nullif(p->>'minutes','')::numeric::int, sort = coalesce(nullif(p->>'sort','')::int, sort),
      open_day = case when (p->>'open_day') ~ '^[0-9]{1,3}$' and (p->>'open_day')::int between 1 and 730 then (p->>'open_day')::int end,
      open_on = case when (p->>'open_on') ~ '^\d{4}-\d{2}-\d{2}$' then (p->>'open_on')::date end where id = lid and not removed;$a$);
  if (length(s) - length(replace(s, 'open_day', ''))) / 8 < 5 then raise notice 'course_lesson_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;
