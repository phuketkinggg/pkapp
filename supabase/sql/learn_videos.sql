-- Videos uploaded straight into the app for course lessons and technique videos, instead of (or as well as) YouTube.
-- They live in a private storage bucket (learn). A video plays only for someone allowed to watch that lesson or technique:
-- staff always; a lesson when it is open for them (free preview, a free course, or bought and released);
-- a technique by its setting (everyone, app, members with a package). Public ones also play on the website.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('learn', 'learn', false, 262144000, array['video/mp4','video/quicktime','video/webm','video/x-m4v'])
on conflict (id) do update set public = false, file_size_limit = 262144000, allowed_mime_types = array['video/mp4','video/quicktime','video/webm','video/x-m4v'];

alter table public.course_lessons add column if not exists video_path text check (video_path is null or video_path ~ '^[a-z0-9/_.-]{1,200}$');
alter table public.techniques add column if not exists video_path text check (video_path is null or video_path ~ '^[a-z0-9/_.-]{1,200}$');

create or replace function private.learn_can_watch(p_name text) returns boolean language plpgsql stable security definer set search_path to '' as $$
declare cid uuid; signed boolean := auth.uid() is not null;
begin
  if signed and private.staff_role() is not null then return true; end if;
  if exists (select 1 from public.techniques t where t.video_path = p_name and not t.removed and t.visibility = 'public') then return true; end if;
  if exists (select 1 from public.course_lessons l join public.courses c on c.id = l.course_id
             where l.video_path = p_name and not l.removed and c.status = 'published' and (l.free or coalesce(c.price_thb,0) = 0)) then return true; end if;
  if not signed then return false; end if;
  cid := private.customer_id();
  if exists (select 1 from public.techniques t where t.video_path = p_name and not t.removed
             and (t.visibility = 'app' or (t.visibility = 'members' and cid is not null and private.has_active_package(cid)))) then return true; end if;
  return exists (select 1 from public.course_lessons l where l.video_path = p_name and not l.removed
             and private.course_open(l.course_id, cid) and private.lesson_released(l, cid));
end $$;

drop policy if exists learn_read on storage.objects;
create policy learn_read on storage.objects for select to anon, authenticated using (bucket_id = 'learn' and private.learn_can_watch(name));
drop policy if exists learn_add on storage.objects;
create policy learn_add on storage.objects for insert to authenticated with check (bucket_id = 'learn' and coalesce(private.staff_role(),'') = 'manager');
drop policy if exists learn_remove on storage.objects;
create policy learn_remove on storage.objects for delete to authenticated using (bucket_id = 'learn' and coalesce(private.staff_role(),'') = 'manager');

-- saving a lesson keeps the uploaded video
do $$ declare s text;
begin
  s := pg_get_functiondef('public.course_lesson_save(jsonb)'::regprocedure);
  if s like '%video_path%' then return; end if;
  s := replace(s, 'insert into public.course_lessons (course_id, sort, title, video_url,', 'insert into public.course_lessons (course_id, video_path, sort, title, video_url,');
  s := replace(s, $a$values ((p->>'course_id')::uuid, coalesce($a$, $a$values ((p->>'course_id')::uuid, case when (p->>'video_path') ~ '^[a-z0-9/_.-]{1,200}$' then p->>'video_path' end, coalesce($a$);
  s := replace(s, 'update public.course_lessons set title = btrim(p->>''title''), video_url = v,', $a$update public.course_lessons set title = btrim(p->>'title'), video_url = v, video_path = case when (p->>'video_path') ~ '^[a-z0-9/_.-]{1,200}$' then p->>'video_path' end,$a$);
  if (length(s) - length(replace(s, 'video_path', ''))) / 10 < 5 then raise notice 'course_lesson_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;

-- the lesson's uploaded video is sent only when the lesson is open, like the YouTube link
do $$ declare s text; f text;
begin
  foreach f in array array['public.course_view(uuid)','public.course_view_as(uuid,uuid)'] loop
    s := pg_get_functiondef(f::regprocedure);
    if s like '%video_path%' then continue; end if;
    s := replace(s, $a$'video', case when (op and private.lesson_released(l, cid)) or l.free then l.video_url end,$a$,
      $a$'video', case when (op and private.lesson_released(l, cid)) or l.free then l.video_url end,
        'video_path', case when (op and private.lesson_released(l, cid)) or l.free then l.video_path end,$a$);
    s := replace(s, $a$'has_video', l.video_url is not null$a$, $a$'has_video', (l.video_url is not null or l.video_path is not null)$a$);
    if s not like '%video_path%' then raise notice '% is a different version here: skipped.', f; continue; end if;
    execute s;
  end loop;
end $$;
do $$ declare s text;
begin
  s := pg_get_functiondef('public.course_public(text)'::regprocedure);
  if s like '%video_path%' then return; end if;
  s := replace(s, $a$'video', case when l.free or coalesce(c.price_thb,0) = 0 then l.video_url end,$a$,
    $a$'video', case when l.free or coalesce(c.price_thb,0) = 0 then l.video_url end, 'video_path', case when l.free or coalesce(c.price_thb,0) = 0 then l.video_path end,$a$);
  s := replace(s, $a$'has_video', l.video_url is not null$a$, $a$'has_video', (l.video_url is not null or l.video_path is not null)$a$);
  if s not like '%video_path%' then raise notice 'course_public is a different version here: skipped.'; return; end if;
  execute s;
end $$;

-- techniques: a YouTube link or an uploaded video
create or replace function private.tech_row(t public.techniques, p_full boolean) returns jsonb language sql stable set search_path to '' as $$
  select jsonb_build_object('id', t.id, 'slug', t.slug, 'title', t.title, 'category', t.category, 'cover', t.cover_url, 'visibility', t.visibility, 'sort', t.sort,
    'updated', t.updated_at, 'has_video', t.video_url is not null or t.video_path is not null, 'locked', not p_full,
    'video', case when p_full then t.video_url end, 'video_path', case when p_full then t.video_path end, 'body', case when p_full then t.body end)
$$;
do $$ declare s text;
begin
  s := pg_get_functiondef('public.technique_save(jsonb)'::regprocedure);
  if s like '%video_path%' then return; end if;
  s := replace(s, 'insert into public.techniques (slug, title,', 'insert into public.techniques (video_path, slug, title,');
  s := replace(s, $a$values (s, trim(p->>'title'),$a$, $a$values (case when (p->>'video_path') ~ '^[a-z0-9/_.-]{1,200}$' then p->>'video_path' end, s, trim(p->>'title'),$a$);
  s := replace(s, $a$update public.techniques set slug = s,$a$, $a$update public.techniques set video_path = case when (p->>'video_path') ~ '^[a-z0-9/_.-]{1,200}$' then p->>'video_path' end, slug = s,$a$);
  if (length(s) - length(replace(s, 'video_path', ''))) / 10 < 5 then raise notice 'technique_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;
