-- Member file (feature member_file): one file per customer, kept for life, for the customer and their team.
-- The file: photo, alerts, health (conditions, medication, allergies, injuries), goals, emergency contact and consent.
-- The diary: a dated note after every coaching session or check-in, with files, each one shared with the member or team only.
-- Documents: anything uploaded (lab reports, doctor's letters, scans, programmes), shared or team only.
-- Who sees it: the member, managers and the coaches assigned to the member (private.coach_can). Every time staff open a file it is logged.
-- Files live in the private storage bucket "coaching" under <customer id>/file/...

create table if not exists public.member_file (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  photo text,
  alerts text not null default '',
  conditions text not null default '',
  medication text not null default '',
  allergies text not null default '',
  injuries text not null default '',
  goals text not null default '',
  emergency_name text not null default '',
  emergency_phone text not null default '',
  consent_at timestamptz,
  consent_how text,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.member_file enable row level security;

create table if not exists public.member_notes (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  day date not null default current_date,
  kind text not null default 'session' check (kind in ('session','checkin','health','note')),
  title text not null default '',
  body text not null default '',
  shared boolean not null default false,
  files jsonb not null default '[]'::jsonb,
  removed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists member_notes_cust on public.member_notes (customer_id, day desc);
alter table public.member_notes enable row level security;

create table if not exists public.member_docs (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  name text not null,
  kind text not null default 'other' check (kind in ('bloods','medical','scan','programme','photo','other')),
  path text not null,
  size integer,
  shared boolean not null default true,
  by_staff uuid references public.staff(id) on delete set null,
  by_member boolean not null default false,
  day date not null default current_date,
  removed boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists member_docs_cust on public.member_docs (customer_id, day desc);
alter table public.member_docs enable row level security;

create table if not exists public.member_file_views (
  id bigserial primary key,
  customer_id uuid not null references public.customers(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  at timestamptz not null default now()
);
create index if not exists member_file_views_cust on public.member_file_views (customer_id, at desc);
alter table public.member_file_views enable row level security;

-- lab reports and letters are often PDFs or Word files: the private coaching bucket takes them too
update storage.buckets set allowed_mime_types = (select array_agg(distinct m) from unnest(coalesce(allowed_mime_types, '{}'::text[]) || array['application/pdf','application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain','image/heic','image/heif']) m)
where id = 'coaching' and allowed_mime_types is not null;

-- staff (coaches with access) may put files in a member's folder too
drop policy if exists "coaching staff upload" on storage.objects;
create policy "coaching staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'coaching' and private.my_staff_id() is not null and (select private.coach_path_ok(name)));

create or replace function private.mf_path_ok(p_customer uuid, p_path text) returns boolean
language sql immutable set search_path to '' as $$
  select p_path like p_customer::text || '/%' and p_path !~ '\.\.' and length(p_path) < 300
$$;

create or replace function private.mf_files(p_customer uuid, p_files jsonb) returns jsonb
language plpgsql immutable set search_path to '' as $$
declare x jsonb; out jsonb := '[]'::jsonb;
begin
  for x in select * from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) loop
    if jsonb_array_length(out) >= 10 then exit; end if;
    if private.mf_path_ok(p_customer, x->>'path') then
      out := out || jsonb_build_array(jsonb_build_object('path', x->>'path', 'name', left(coalesce(x->>'name', 'File'), 120), 'type', left(coalesce(x->>'type', ''), 60)));
    end if;
  end loop;
  return out;
end $$;

-- the whole file for staff; each look is logged
create or replace function public.member_file_get(p_customer uuid) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare me uuid := private.my_staff_id(); mgr boolean := coalesce(private.staff_role(), '') = 'manager';
begin
  if me is null or not private.coach_can(p_customer) then raise exception 'Only this member''s coaches and the managers can open their file.'; end if;
  insert into public.member_file_views (customer_id, staff_id) values (p_customer, me);
  return jsonb_build_object(
    'file', coalesce((select to_jsonb(f) from public.member_file f where f.customer_id = p_customer), jsonb_build_object('customer_id', p_customer)),
    'intake_photo', (select i.photo_path from public.customer_intake i where i.customer_id = p_customer),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'day', n.day, 'kind', n.kind, 'title', n.title, 'body', n.body, 'shared', n.shared, 'files', n.files,
        'staff_id', n.staff_id, 'by', s.name, 'mine', n.staff_id = me, 'at', n.created_at) order by n.day desc, n.created_at desc)
      from public.member_notes n left join public.staff s on s.id = n.staff_id where n.customer_id = p_customer and not n.removed), '[]'::jsonb),
    'docs', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'kind', d.kind, 'path', d.path, 'size', d.size, 'shared', d.shared, 'day', d.day,
        'by', case when d.by_member then 'Member' else s.name end) order by d.day desc, d.created_at desc)
      from public.member_docs d left join public.staff s on s.id = d.by_staff where d.customer_id = p_customer and not d.removed), '[]'::jsonb),
    'views', case when mgr then coalesce((select jsonb_agg(jsonb_build_object('at', v.at, 'by', s.name) order by v.at desc)
      from (select * from public.member_file_views where customer_id = p_customer order by at desc limit 30) v left join public.staff s on s.id = v.staff_id), '[]'::jsonb) else null end);
end $$;

create or replace function public.member_file_save(p_customer uuid, p jsonb) returns void
language plpgsql security definer set search_path to '' as $$
declare me uuid := private.my_staff_id(); nm text;
begin
  if me is null or not private.coach_can(p_customer) then raise exception 'Not allowed.'; end if;
  select name into nm from public.staff where id = me;
  if p ? 'photo' and p->>'photo' is not null and not private.mf_path_ok(p_customer, p->>'photo') then raise exception 'That photo is not in this member''s folder.'; end if;
  insert into public.member_file as f (customer_id, photo, alerts, conditions, medication, allergies, injuries, goals, emergency_name, emergency_phone, updated_at, updated_by)
  values (p_customer, p->>'photo', left(coalesce(p->>'alerts',''),2000), left(coalesce(p->>'conditions',''),4000), left(coalesce(p->>'medication',''),4000), left(coalesce(p->>'allergies',''),2000),
    left(coalesce(p->>'injuries',''),4000), left(coalesce(p->>'goals',''),4000), left(coalesce(p->>'emergency_name',''),120), left(coalesce(p->>'emergency_phone',''),40), now(), nm)
  on conflict (customer_id) do update set
    photo = case when p ? 'photo' then excluded.photo else f.photo end,
    alerts = case when p ? 'alerts' then excluded.alerts else f.alerts end,
    conditions = case when p ? 'conditions' then excluded.conditions else f.conditions end,
    medication = case when p ? 'medication' then excluded.medication else f.medication end,
    allergies = case when p ? 'allergies' then excluded.allergies else f.allergies end,
    injuries = case when p ? 'injuries' then excluded.injuries else f.injuries end,
    goals = case when p ? 'goals' then excluded.goals else f.goals end,
    emergency_name = case when p ? 'emergency_name' then excluded.emergency_name else f.emergency_name end,
    emergency_phone = case when p ? 'emergency_phone' then excluded.emergency_phone else f.emergency_phone end,
    updated_at = now(), updated_by = nm;
end $$;

-- consent the member gave in person (they can also give it in their app)
create or replace function public.member_consent_set(p_customer uuid, p_on boolean) returns void
language plpgsql security definer set search_path to '' as $$
declare me uuid := private.my_staff_id(); nm text;
begin
  if me is null or not private.coach_can(p_customer) then raise exception 'Not allowed.'; end if;
  select name into nm from public.staff where id = me;
  insert into public.member_file as f (customer_id, consent_at, consent_how) values (p_customer, case when p_on then now() end, case when p_on then 'In person, recorded by ' || nm end)
  on conflict (customer_id) do update set consent_at = case when p_on then now() end, consent_how = case when p_on then 'In person, recorded by ' || nm else 'Taken back, recorded by ' || nm end;
end $$;

create or replace function public.member_note_save(p jsonb) returns uuid
language plpgsql security definer set search_path to '' as $$
declare me uuid := private.my_staff_id(); cid uuid := (p->>'customer_id')::uuid; nid uuid := nullif(p->>'id','')::uuid; o public.member_notes%rowtype;
begin
  if me is null or not private.coach_can(cid) then raise exception 'Not allowed.'; end if;
  if btrim(coalesce(p->>'body','')) = '' and btrim(coalesce(p->>'title','')) = '' and jsonb_array_length(coalesce(p->'files','[]'::jsonb)) = 0 then raise exception 'Write the note first.'; end if;
  if nid is null then
    insert into public.member_notes (customer_id, staff_id, day, kind, title, body, shared, files)
    values (cid, me, coalesce((p->>'day')::date, current_date), coalesce(nullif(p->>'kind',''),'session'), left(coalesce(p->>'title',''),200), left(coalesce(p->>'body',''),20000),
      coalesce((p->>'shared')::boolean, false), private.mf_files(cid, p->'files')) returning id into nid;
  else
    select * into o from public.member_notes where id = nid and customer_id = cid and not removed;
    if o.id is null then raise exception 'That note is not there any more.'; end if;
    if o.staff_id is distinct from me and coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the coach who wrote it, or a manager, can change a note.'; end if;
    update public.member_notes set day = coalesce((p->>'day')::date, day), kind = coalesce(nullif(p->>'kind',''), kind), title = left(coalesce(p->>'title',''),200), body = left(coalesce(p->>'body',''),20000),
      shared = coalesce((p->>'shared')::boolean, shared), files = private.mf_files(cid, p->'files'), updated_at = now() where id = nid;
  end if;
  return nid;
end $$;

create or replace function public.member_note_remove(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare o public.member_notes%rowtype;
begin
  select * into o from public.member_notes where id = p_id;
  if o.id is null or not private.coach_can(o.customer_id) then raise exception 'Not allowed.'; end if;
  if o.staff_id is distinct from private.my_staff_id() and coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the coach who wrote it, or a manager, can remove a note.'; end if;
  update public.member_notes set removed = true, updated_at = now() where id = p_id;
end $$;

create or replace function public.member_doc_add(p jsonb) returns uuid
language plpgsql security definer set search_path to '' as $$
declare me uuid := private.my_staff_id(); cid uuid := (p->>'customer_id')::uuid; mine uuid := private.customer_id(); v uuid; k text := coalesce(nullif(p->>'kind',''),'other');
begin
  if cid is null then cid := mine; end if;
  if not (cid = mine or (me is not null and private.coach_can(cid))) then raise exception 'Not allowed.'; end if;
  if not private.mf_path_ok(cid, p->>'path') then raise exception 'That file is not in this member''s folder.'; end if;
  if k not in ('bloods','medical','scan','programme','photo','other') then k := 'other'; end if;
  insert into public.member_docs (customer_id, name, kind, path, size, shared, by_staff, by_member, day)
  values (cid, left(coalesce(nullif(btrim(p->>'name'),''),'File'),160), k, p->>'path', (p->>'size')::int,
    case when cid = mine and me is null then true else coalesce((p->>'shared')::boolean, true) end, me, me is null, coalesce((p->>'day')::date, current_date))
  returning id into v;
  return v;
end $$;

create or replace function public.member_doc_remove(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare d public.member_docs%rowtype;
begin
  select * into d from public.member_docs where id = p_id;
  if d.id is null then raise exception 'That file is not there any more.'; end if;
  if not ((d.by_member and d.customer_id = private.customer_id()) or (private.my_staff_id() is not null and private.coach_can(d.customer_id))) then raise exception 'Not allowed.'; end if;
  update public.member_docs set removed = true where id = p_id;
end $$;

create or replace function public.member_doc_share(p_id uuid, p_shared boolean) returns void
language plpgsql security definer set search_path to '' as $$
declare d public.member_docs%rowtype;
begin
  select * into d from public.member_docs where id = p_id;
  if d.id is null or private.my_staff_id() is null or not private.coach_can(d.customer_id) then raise exception 'Not allowed.'; end if;
  update public.member_docs set shared = p_shared where id = p_id;
end $$;

-- the member's own file in their app: everything about them except notes the team kept to itself
create or replace function public.my_file() returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare cid uuid := private.customer_id();
begin
  if cid is null then raise exception 'Sign in first.'; end if;
  return jsonb_build_object(
    'file', coalesce((select to_jsonb(f) - 'updated_by' from public.member_file f where f.customer_id = cid), jsonb_build_object('customer_id', cid)),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'day', n.day, 'kind', n.kind, 'title', n.title, 'body', n.body, 'files', n.files, 'by', s.name) order by n.day desc, n.created_at desc)
      from public.member_notes n left join public.staff s on s.id = n.staff_id where n.customer_id = cid and n.shared and not n.removed), '[]'::jsonb),
    'docs', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'kind', d.kind, 'path', d.path, 'day', d.day, 'mine', d.by_member) order by d.day desc, d.created_at desc)
      from public.member_docs d where d.customer_id = cid and (d.shared or d.by_member) and not d.removed), '[]'::jsonb),
    'coaches', coalesce((select jsonb_agg(s.name order by s.name) from public.coach_clients cc join public.staff s on s.id = cc.staff_id where cc.customer_id = cid), '[]'::jsonb));
end $$;

-- the member keeps their own health details up to date
create or replace function public.my_file_save(p jsonb) returns void
language plpgsql security definer set search_path to '' as $$
declare cid uuid := private.customer_id();
begin
  if cid is null then raise exception 'Sign in first.'; end if;
  if p ? 'photo' and p->>'photo' is not null and not private.mf_path_ok(cid, p->>'photo') then raise exception 'That photo is not in your folder.'; end if;
  insert into public.member_file as f (customer_id, photo, conditions, medication, allergies, injuries, goals, emergency_name, emergency_phone, updated_at, updated_by)
  values (cid, p->>'photo', left(coalesce(p->>'conditions',''),4000), left(coalesce(p->>'medication',''),4000), left(coalesce(p->>'allergies',''),2000), left(coalesce(p->>'injuries',''),4000),
    left(coalesce(p->>'goals',''),4000), left(coalesce(p->>'emergency_name',''),120), left(coalesce(p->>'emergency_phone',''),40), now(), 'Member')
  on conflict (customer_id) do update set
    photo = case when p ? 'photo' then excluded.photo else f.photo end,
    conditions = case when p ? 'conditions' then excluded.conditions else f.conditions end,
    medication = case when p ? 'medication' then excluded.medication else f.medication end,
    allergies = case when p ? 'allergies' then excluded.allergies else f.allergies end,
    injuries = case when p ? 'injuries' then excluded.injuries else f.injuries end,
    goals = case when p ? 'goals' then excluded.goals else f.goals end,
    emergency_name = case when p ? 'emergency_name' then excluded.emergency_name else f.emergency_name end,
    emergency_phone = case when p ? 'emergency_phone' then excluded.emergency_phone else f.emergency_phone end,
    updated_at = now(), updated_by = 'Member';
end $$;

create or replace function public.my_consent(p_on boolean) returns void
language plpgsql security definer set search_path to '' as $$
declare cid uuid := private.customer_id();
begin
  if cid is null then raise exception 'Sign in first.'; end if;
  insert into public.member_file as f (customer_id, consent_at, consent_how) values (cid, case when p_on then now() end, case when p_on then 'In the app' end)
  on conflict (customer_id) do update set consent_at = case when p_on then now() end, consent_how = case when p_on then 'In the app' else 'Taken back in the app' end;
end $$;

revoke all on function public.member_file_get(uuid), public.member_file_save(uuid, jsonb), public.member_consent_set(uuid, boolean), public.member_note_save(jsonb),
  public.member_note_remove(uuid), public.member_doc_add(jsonb), public.member_doc_remove(uuid), public.member_doc_share(uuid, boolean),
  public.my_file(), public.my_file_save(jsonb), public.my_consent(boolean) from public, anon;
grant execute on function public.member_file_get(uuid), public.member_file_save(uuid, jsonb), public.member_consent_set(uuid, boolean), public.member_note_save(jsonb),
  public.member_note_remove(uuid), public.member_doc_add(jsonb), public.member_doc_remove(uuid), public.member_doc_share(uuid, boolean),
  public.my_file(), public.my_file_save(jsonb), public.my_consent(boolean) to authenticated;
revoke all on function private.mf_path_ok(uuid, text), private.mf_files(uuid, jsonb) from public, anon, authenticated;
