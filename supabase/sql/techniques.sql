-- Education: next to the courses, a technique library. Single videos (YouTube) with notes, in categories.
-- Each video chooses who sees it: public (website and app), app (anyone with the app), members (an active package),
-- hidden (only used inside courses). Also: offers shown to customers without coaching (Coaching tab).

create table if not exists public.techniques (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]{1,80}$'),
  title text not null,
  category text not null default '',
  video_url text check (video_url is null or video_url ~ '^https://'),
  cover_url text check (cover_url is null or cover_url ~ '^https://'),
  body text,
  visibility text not null default 'app' check (visibility in ('public','app','members','hidden')),
  sort integer not null default 0,
  removed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
alter table public.techniques enable row level security;
revoke all on public.techniques from anon, authenticated;

insert into public.app_settings (key, value) values ('coach_offers', '[]') on conflict (key) do nothing;

create or replace function private.tech_row(t public.techniques, p_full boolean) returns jsonb language sql stable set search_path to '' as $$
  select jsonb_build_object('id', t.id, 'slug', t.slug, 'title', t.title, 'category', t.category, 'cover', t.cover_url, 'visibility', t.visibility, 'sort', t.sort,
    'updated', t.updated_at, 'has_video', t.video_url is not null, 'locked', not p_full,
    'video', case when p_full then t.video_url end, 'body', case when p_full then t.body end)
$$;

-- managers: add or change a video (returns its id)
create or replace function public.technique_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid; s text; base text; n int := 1;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change the technique library.'; end if;
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'Add a name for the video.'; end if;
  if nullif(p->>'video_url','') is not null and (p->>'video_url') !~ '^https://' then raise exception 'The video must be a link starting with https://'; end if;
  if coalesce(p->>'visibility','app') not in ('public','app','members','hidden') then raise exception 'Choose who can see it.'; end if;
  base := left(trim(both '-' from regexp_replace(lower(coalesce(nullif(p->>'slug',''), p->>'title')), '[^a-z0-9]+', '-', 'g')), 70);
  if base = '' then base := 'technique'; end if;
  s := base;
  while exists (select 1 from public.techniques where slug = s and id is distinct from v) loop n := n + 1; s := base || '-' || n; end loop;
  if v is null then
    insert into public.techniques (slug, title, category, video_url, cover_url, body, visibility, sort)
    values (s, trim(p->>'title'), coalesce(trim(p->>'category'),''), nullif(p->>'video_url',''), nullif(p->>'cover_url',''), p->>'body', coalesce(p->>'visibility','app'), coalesce(nullif(p->>'sort','')::numeric::int, 0))
    returning id into v;
  else
    update public.techniques set slug = s, title = trim(p->>'title'), category = coalesce(trim(p->>'category'),''), video_url = nullif(p->>'video_url',''),
      cover_url = nullif(p->>'cover_url',''), body = p->>'body', visibility = coalesce(p->>'visibility','app'), sort = coalesce(nullif(p->>'sort','')::numeric::int, 0), updated_at = now()
    where id = v and not removed;
    if not found then raise exception 'Not found.'; end if;
  end if;
  return v;
end $$;
revoke all on function public.technique_save(jsonb) from public, anon;
grant execute on function public.technique_save(jsonb) to authenticated;

create or replace function public.technique_remove(p_id uuid) returns void language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change the technique library.'; end if;
  update public.techniques set removed = true, updated_at = now() where id = p_id;
end $$;
revoke all on function public.technique_remove(uuid) from public, anon;
grant execute on function public.technique_remove(uuid) to authenticated;

-- the library in the app: staff see everything; a customer sees public and app videos, and members videos with an active package
-- (without one they see the name, locked). p_customer: a manager looking as that customer (Customer view).
create or replace function public.technique_list(p_customer uuid default null) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare st text := private.staff_role(); cid uuid; mem boolean;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_customer is not null then
    if coalesce(st,'') not in ('manager','front_desk','resort') then raise exception 'Not allowed.'; end if;
    cid := p_customer; st := null;
  else cid := private.customer_id(); end if;
  if st is not null then
    return (select coalesce(jsonb_agg(private.tech_row(t, true) order by t.category, t.sort, t.title), '[]'::jsonb) from public.techniques t where not t.removed);
  end if;
  mem := cid is not null and private.has_active_package(cid);
  return (select coalesce(jsonb_agg(private.tech_row(t, t.visibility <> 'members' or mem) order by t.category, t.sort, t.title), '[]'::jsonb)
    from public.techniques t where not t.removed and t.visibility in ('public','app','members'));
end $$;
revoke all on function public.technique_list(uuid) from public, anon;
grant execute on function public.technique_list(uuid) to authenticated;

-- the website: public videos only
create or replace function public.technique_public(p_slug text default null) returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(private.tech_row(t, true) order by t.category, t.sort, t.title), '[]'::jsonb)
  from public.techniques t where not t.removed and t.visibility = 'public' and (p_slug is null or t.slug = p_slug)
$$;
revoke all on function public.technique_public(text) from public;
grant execute on function public.technique_public(text) to anon, authenticated;

-- offers in the Coaching tab for customers without coaching (managers write app_settings coach_offers)
create or replace function public.coach_offers() returns jsonb language sql stable security definer set search_path to '' as $$
  select case when auth.uid() is null then '[]'::jsonb else coalesce((select case when value ~ '^\s*\[' then value::jsonb end from public.app_settings where key = 'coach_offers'), '[]'::jsonb) end
$$;
revoke all on function public.coach_offers() from public, anon;
grant execute on function public.coach_offers() to authenticated;
