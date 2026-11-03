delete from mf.template where name like 'coach_docs:%';
insert into mf.template (ord, phase, kind, name, sql) values (300601, 3, 'patch', 'coach_docs:300601', $TPL$create table if not exists __P__.coach_docs (
  id uuid primary key default gen_random_uuid(),
  title text not null, notes text, url text not null, path text, size_kb integer, mime text,
  created_by uuid, created_at timestamptz not null default now(), removed boolean not null default false);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300602, 3, 'patch', 'coach_docs:300602', $TPL$alter table __P__.coach_docs enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103501, 11, 'patch', 'coach_docs:1103501', $TPL$revoke all on __P__.coach_docs from anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400901, 4, 'patch', 'coach_docs:400901', $TPL$create or replace function __P__.coach_docs_list() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not __Q__.coach_staff() then raise exception 'Only coaches and managers can see coaching documents.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'notes', d.notes, 'url', d.url, 'size_kb', d.size_kb, 'mime', d.mime, 'at', d.created_at,
      'groups', (select coalesce(jsonb_agg(g.name order by g.name), '[]'::jsonb) from __P__.action_groups g
                  where not g.removed and exists (select 1 from jsonb_array_elements(g.items) x where x->>'url' = d.url)),
      'lessons', (select count(*) from __P__.course_lessons l where not l.removed and l.files::text like '%' || d.url || '%'))
    order by d.created_at desc) from __P__.coach_docs d where not d.removed), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400902, 4, 'patch', 'coach_docs:400902', $TPL$create or replace function __P__.coach_doc_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v uuid := nullif(p->>'id', '')::uuid;
begin
  if not __Q__.coach_staff() then raise exception 'Only coaches and managers can change coaching documents.'; end if;
  if btrim(coalesce(p->>'title', '')) = '' then raise exception 'Give the document a name.'; end if;
  if v is null then
    if coalesce(p->>'url', '') !~ '^https://' then raise exception 'Upload the file first.'; end if;
    insert into __P__.coach_docs (title, notes, url, path, size_kb, mime, created_by)
    values (left(btrim(p->>'title'), 140), left(coalesce(p->>'notes', ''), 1000), p->>'url', p->>'path', nullif(p->>'size_kb', '')::int, left(p->>'mime', 100), __Q__.my_staff_id())
    returning id into v;
  else
    update __P__.coach_docs set title = left(btrim(p->>'title'), 140), notes = left(coalesce(p->>'notes', ''), 1000) where id = v and not removed;
    if not found then raise exception 'That document was not found.'; end if;
  end if;
  return v;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400903, 4, 'patch', 'coach_docs:400903', $TPL$create or replace function __P__.coach_doc_remove(p_id uuid) returns text language plpgsql security definer set search_path to '' as $f$
declare pth text;
begin
  if not __Q__.coach_staff() then raise exception 'Only coaches and managers can change coaching documents.'; end if;
  update __P__.coach_docs set removed = true where id = p_id and not removed returning path into pth;
  return pth; -- the app removes the file from storage
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103502, 11, 'patch', 'coach_docs:1103502', $TPL$revoke all on function __P__.coach_docs_list(), __P__.coach_doc_save(jsonb), __P__.coach_doc_remove(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103503, 11, 'patch', 'coach_docs:1103503', $TPL$grant execute on function __P__.coach_docs_list(), __P__.coach_doc_save(jsonb), __P__.coach_doc_remove(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300603, 3, 'patch', 'coach_docs:300603', $TPL$alter table __P__.action_groups add column if not exists auto_join text;      -- null (off), 'all' or 'tags'
alter table __P__.action_groups add column if not exists auto_tags text[];$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400904, 4, 'patch', 'coach_docs:400904', $TPL$create or replace function __P__.group_auto_set(p_group uuid, p_mode text, p_tags text[]) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change who joins by themselves.'; end if;
  if p_mode is not null and p_mode not in ('all', 'tags') then raise exception 'Unknown choice.'; end if;
  if p_mode = 'tags' and coalesce(array_length(p_tags, 1), 0) = 0 then raise exception 'Pick one or more tags.'; end if;
  update __P__.action_groups set auto_join = p_mode, auto_tags = case when p_mode = 'tags' then p_tags else null end, updated_at = now() where id = p_group and not removed;
  if not found then raise exception 'That group was not found.'; end if;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103504, 11, 'patch', 'coach_docs:1103504', $TPL$revoke all on function __P__.group_auto_set(uuid, text, text[]) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103505, 11, 'patch', 'coach_docs:1103505', $TPL$grant execute on function __P__.group_auto_set(uuid, text, text[]) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400905, 4, 'patch', 'coach_docs:400905', $TPL$create or replace function __Q__.group_auto_join() returns trigger language plpgsql security definer set search_path to '' as $f$
declare g record; m uuid;
begin
  if coalesce(new.is_agency, false) then return new; end if;
  for g in select * from __P__.action_groups ag where not ag.removed and ag.auto_join is not null
      and (ag.auto_join = 'all' and tg_op = 'INSERT'
           or ag.auto_join = 'tags' and coalesce(new.tags, '{}') && coalesce(ag.auto_tags, '{}')
              and (tg_op = 'INSERT' or not (coalesce(old.tags, '{}') && coalesce(ag.auto_tags, '{}'))))
  loop
    if exists (select 1 from __P__.group_members gm where gm.group_id = g.id and gm.customer_id = new.id and not gm.removed) then continue; end if;
    insert into __P__.group_members (group_id, customer_id, start_on, added_by) values (g.id, new.id, __Q__.bkk_today(), null) returning id into m;
    begin perform __Q__.group_apply(m); exception when others then null; end;
  end loop;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900301, 9, 'patch', 'coach_docs:900301', $TPL$drop trigger if exists group_auto_join on __P__.customers;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900302, 9, 'patch', 'coach_docs:900302', $TPL$create trigger group_auto_join after insert or update of tags on __P__.customers for each row execute function __Q__.group_auto_join();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400906, 4, 'patch', 'coach_docs:400906', $TPL$create or replace function __P__.group_auto_get() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_object_agg(id, jsonb_build_object('mode', auto_join, 'tags', auto_tags)), '{}'::jsonb) from __P__.action_groups where not removed and auto_join is not null and __Q__.coach_staff()
$$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103506, 11, 'patch', 'coach_docs:1103506', $TPL$revoke all on function __P__.group_auto_get() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103507, 11, 'patch', 'coach_docs:1103507', $TPL$grant execute on function __P__.group_auto_get() to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'coach_docs:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
update storage.buckets set allowed_mime_types = (select array_agg(distinct m) from unnest(coalesce(allowed_mime_types, '{}') || array[
  'application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'text/plain']) m)
where id = 'coach-media' and allowed_mime_types is not null;
notify pgrst, 'reload schema';
