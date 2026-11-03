-- Coaching documents (feature coach_docs): PDFs and other files uploaded once to a library, then used in action groups
-- (a Document step) and in Education (lesson files). Files sit in the coach-media storage bucket under docs/.
-- Action groups can also add new customers by themselves (everyone, or customers with chosen tags), starting the day they join.
create table if not exists public.coach_docs (
  id uuid primary key default gen_random_uuid(),
  title text not null, notes text, url text not null, path text, size_kb integer, mime text,
  created_by uuid, created_at timestamptz not null default now(), removed boolean not null default false);
alter table public.coach_docs enable row level security;
revoke all on public.coach_docs from anon, authenticated;

create or replace function public.coach_docs_list() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can see coaching documents.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'notes', d.notes, 'url', d.url, 'size_kb', d.size_kb, 'mime', d.mime, 'at', d.created_at,
      'groups', (select coalesce(jsonb_agg(g.name order by g.name), '[]'::jsonb) from public.action_groups g
                  where not g.removed and exists (select 1 from jsonb_array_elements(g.items) x where x->>'url' = d.url)),
      'lessons', (select count(*) from public.course_lessons l where not l.removed and l.files::text like '%' || d.url || '%'))
    order by d.created_at desc) from public.coach_docs d where not d.removed), '[]'::jsonb);
end $f$;

create or replace function public.coach_doc_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v uuid := nullif(p->>'id', '')::uuid;
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can change coaching documents.'; end if;
  if btrim(coalesce(p->>'title', '')) = '' then raise exception 'Give the document a name.'; end if;
  if v is null then
    if coalesce(p->>'url', '') !~ '^https://' then raise exception 'Upload the file first.'; end if;
    insert into public.coach_docs (title, notes, url, path, size_kb, mime, created_by)
    values (left(btrim(p->>'title'), 140), left(coalesce(p->>'notes', ''), 1000), p->>'url', p->>'path', nullif(p->>'size_kb', '')::int, left(p->>'mime', 100), private.my_staff_id())
    returning id into v;
  else
    update public.coach_docs set title = left(btrim(p->>'title'), 140), notes = left(coalesce(p->>'notes', ''), 1000) where id = v and not removed;
    if not found then raise exception 'That document was not found.'; end if;
  end if;
  return v;
end $f$;

create or replace function public.coach_doc_remove(p_id uuid) returns text language plpgsql security definer set search_path to '' as $f$
declare pth text;
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can change coaching documents.'; end if;
  update public.coach_docs set removed = true where id = p_id and not removed returning path into pth;
  return pth; -- the app removes the file from storage
end $f$;
revoke all on function public.coach_docs_list(), public.coach_doc_save(jsonb), public.coach_doc_remove(uuid) from public, anon;
grant execute on function public.coach_docs_list(), public.coach_doc_save(jsonb), public.coach_doc_remove(uuid) to authenticated;

-- action groups that add new customers by themselves
alter table public.action_groups add column if not exists auto_join text;      -- null (off), 'all' or 'tags'
alter table public.action_groups add column if not exists auto_tags text[];

create or replace function public.group_auto_set(p_group uuid, p_mode text, p_tags text[]) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change who joins by themselves.'; end if;
  if p_mode is not null and p_mode not in ('all', 'tags') then raise exception 'Unknown choice.'; end if;
  if p_mode = 'tags' and coalesce(array_length(p_tags, 1), 0) = 0 then raise exception 'Pick one or more tags.'; end if;
  update public.action_groups set auto_join = p_mode, auto_tags = case when p_mode = 'tags' then p_tags else null end, updated_at = now() where id = p_group and not removed;
  if not found then raise exception 'That group was not found.'; end if;
end $f$;
revoke all on function public.group_auto_set(uuid, text, text[]) from public, anon;
grant execute on function public.group_auto_set(uuid, text, text[]) to authenticated;

-- a new customer (or one given a matching tag) joins every group set to add them, starting today
create or replace function private.group_auto_join() returns trigger language plpgsql security definer set search_path to '' as $f$
declare g record; m uuid;
begin
  if coalesce(new.is_agency, false) then return new; end if;
  for g in select * from public.action_groups ag where not ag.removed and ag.auto_join is not null
      and (ag.auto_join = 'all' and tg_op = 'INSERT'
           or ag.auto_join = 'tags' and coalesce(new.tags, '{}') && coalesce(ag.auto_tags, '{}')
              and (tg_op = 'INSERT' or not (coalesce(old.tags, '{}') && coalesce(ag.auto_tags, '{}'))))
  loop
    if exists (select 1 from public.group_members gm where gm.group_id = g.id and gm.customer_id = new.id and not gm.removed) then continue; end if;
    insert into public.group_members (group_id, customer_id, start_on, added_by) values (g.id, new.id, private.bkk_today(), null) returning id into m;
    begin perform private.group_apply(m); exception when others then null; end;
  end loop;
  return new;
end $f$;
drop trigger if exists group_auto_join on public.customers;
create trigger group_auto_join after insert or update of tags on public.customers for each row execute function private.group_auto_join();
create or replace function public.group_auto_get() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_object_agg(id, jsonb_build_object('mode', auto_join, 'tags', auto_tags)), '{}'::jsonb) from public.action_groups where not removed and auto_join is not null and private.coach_staff()
$$;
revoke all on function public.group_auto_get() from public, anon;
grant execute on function public.group_auto_get() to authenticated;

-- the coaching file bucket also takes Excel and PowerPoint files
update storage.buckets set allowed_mime_types = (select array_agg(distinct m) from unnest(coalesce(allowed_mime_types, '{}') || array[
  'application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'text/plain']) m)
where id = 'coach-media' and allowed_mime_types is not null;
notify pgrst, 'reload schema';
