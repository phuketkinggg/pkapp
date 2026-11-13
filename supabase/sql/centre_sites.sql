-- Centres and their websites (feature centre_sites, off unless switched on; on for Pangea): each centre (pangea_locations) has its
-- own page on the main website at /<slug>, filled from the back office: name, place, what it is known for, a short line, the
-- story, a photo, highlights, contact, map and booking. A centre can take its live prices, class times and team from another
-- business's public website data (data_url, for example the Phuket King system for Pangea Phuket): read only, nothing is written there.
-- Planned centres take "tell me when it opens" sign ups (pangea_interest), which managers see in the back office.

alter table public.pangea_locations add column if not exists slug text;
alter table public.pangea_locations add column if not exists tagline text;
alter table public.pangea_locations add column if not exists about text;
alter table public.pangea_locations add column if not exists hero_url text;
alter table public.pangea_locations add column if not exists highlights jsonb not null default '[]'::jsonb;
alter table public.pangea_locations add column if not exists whatsapp text;
alter table public.pangea_locations add column if not exists email text;
alter table public.pangea_locations add column if not exists address text;
alter table public.pangea_locations add column if not exists map_url text;
alter table public.pangea_locations add column if not exists book_url text;
alter table public.pangea_locations add column if not exists data_url text;
alter table public.pangea_locations add column if not exists published boolean not null default true;
alter table public.pangea_locations add column if not exists updated_at timestamptz;
create unique index if not exists pangea_locations_slug on public.pangea_locations (lower(slug)) where slug is not null;

create table if not exists public.pangea_interest (
  id uuid primary key default gen_random_uuid(),
  location_id uuid references public.pangea_locations (id) on delete cascade,
  name text,
  email text not null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists pangea_interest_loc on public.pangea_interest (location_id, created_at desc);
alter table public.pangea_interest enable row level security;
revoke all on public.pangea_interest from public, anon, authenticated;

create or replace function private.url_ok(u text) returns text language sql immutable as $f$
  select case when u ~ '^https://[A-Za-z0-9.-]+(/[^\s<>"]*)?$' and length(u) < 500 then u end
$f$;

-- the public website: every published centre, newest settings, no private data
create or replace function public.pangea_site() returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('centres', coalesce(jsonb_agg(jsonb_build_object('slug', l.slug, 'name', l.name, 'place', l.place, 'focus', l.focus, 'blurb', l.blurb,
      'tagline', l.tagline, 'about', l.about, 'hero', l.hero_url, 'highlights', l.highlights, 'whatsapp', l.whatsapp, 'email', l.email, 'address', l.address,
      'map', l.map_url, 'book', l.book_url, 'data', l.data_url, 'status', l.status) order by l.sort, l.name), '[]'::jsonb))
  from public.pangea_locations l where l.published and private.feature('centre_sites', false)
$f$;
revoke all on function public.pangea_site() from public;
grant execute on function public.pangea_site() to anon, authenticated;

-- "tell me when it opens" from a centre's page
create or replace function public.pangea_interest_add(p_slug text, p_name text, p_email text, p_note text) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare loc uuid; em text := lower(btrim(coalesce(p_email, '')));
begin
  if not private.feature('centre_sites', false) then raise exception 'Not available.'; end if;
  if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or length(em) > 200 then raise exception 'Type your email.'; end if;
  select id into loc from public.pangea_locations where lower(slug) = lower(btrim(coalesce(p_slug, ''))) and published;
  if loc is null then raise exception 'That centre was not found.'; end if;
  if (select count(*) from public.pangea_interest where email = em and created_at > now() - interval '1 day') >= 5 then return jsonb_build_object('ok', true); end if;
  if exists (select 1 from public.pangea_interest where email = em and location_id = loc) then return jsonb_build_object('ok', true); end if;
  insert into public.pangea_interest (location_id, name, email, note) values (loc, left(nullif(btrim(coalesce(p_name, '')), ''), 120), em, left(nullif(btrim(coalesce(p_note, '')), ''), 1000));
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.pangea_interest_add(text, text, text, text) from public;
grant execute on function public.pangea_interest_add(text, text, text, text) to anon, authenticated;

-- the back office: every centre, published or not, with how many asked to hear when it opens
create or replace function public.centres_admin() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(l) - 'created_at' || jsonb_build_object('interest', (select count(*) from public.pangea_interest i where i.location_id = l.id),
      'members', (select count(*) from public.pangea_service s where s.location_id = l.id)) order by l.sort, l.name) from public.pangea_locations l), '[]'::jsonb);
end $f$;

create or replace function public.centre_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare cid uuid := nullif(p->>'id', '')::uuid; sl text := lower(regexp_replace(btrim(coalesce(p->>'slug', '')), '[^a-zA-Z0-9-]+', '-', 'g')); hl jsonb := '[]'::jsonb; x jsonb;
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if btrim(coalesce(p->>'name', '')) = '' then raise exception 'Type the name.'; end if;
  sl := btrim(sl, '-');
  if sl = '' then raise exception 'Type the web address, for example phuket.'; end if;
  if sl in ('app','admin','team','book','cafe','privacy','api','www','media','icons','centre','index','404') then raise exception 'Choose another web address, % is taken.', sl; end if;
  if exists (select 1 from public.pangea_locations where lower(slug) = sl and id is distinct from cid) then raise exception 'Another centre already uses /%.', sl; end if;
  if jsonb_typeof(p->'highlights') = 'array' then
    for x in select * from jsonb_array_elements(p->'highlights') limit 12 loop
      if btrim(coalesce(x->>'title', '')) <> '' then hl := hl || jsonb_build_object('title', left(btrim(x->>'title'), 80), 'text', left(btrim(coalesce(x->>'text', '')), 400)); end if;
    end loop;
  end if;
  if cid is null then
    insert into public.pangea_locations (name, sort, status) values (left(btrim(p->>'name'), 80), coalesce(nullif(p->>'sort', '')::int, 100), 'soon') returning id into cid;
  end if;
  update public.pangea_locations set
    name = left(btrim(p->>'name'), 80), slug = sl, place = left(nullif(btrim(coalesce(p->>'place', '')), ''), 120), focus = left(nullif(btrim(coalesce(p->>'focus', '')), ''), 160),
    blurb = left(nullif(btrim(coalesce(p->>'blurb', '')), ''), 400), tagline = left(nullif(btrim(coalesce(p->>'tagline', '')), ''), 160), about = left(nullif(btrim(coalesce(p->>'about', '')), ''), 6000),
    hero_url = private.url_ok(btrim(coalesce(p->>'hero_url', ''))), highlights = hl,
    whatsapp = left(nullif(regexp_replace(coalesce(p->>'whatsapp', ''), '[^0-9+]', '', 'g'), ''), 20), email = left(nullif(btrim(coalesce(p->>'email', '')), ''), 200),
    address = left(nullif(btrim(coalesce(p->>'address', '')), ''), 300), map_url = private.url_ok(btrim(coalesce(p->>'map_url', ''))),
    book_url = private.url_ok(btrim(coalesce(p->>'book_url', ''))), data_url = private.url_ok(btrim(coalesce(p->>'data_url', ''))),
    status = case when p->>'status' in ('open','soon') then p->>'status' else status end, sort = coalesce(nullif(p->>'sort', '')::int, sort),
    published = coalesce((p->>'published')::boolean, published), updated_at = now()
  where id = cid;
  return cid;
end $f$;

create or replace function public.centre_remove(p_id uuid) returns jsonb language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if exists (select 1 from public.pangea_service where location_id = p_id) then
    update public.pangea_locations set published = false, updated_at = now() where id = p_id;
    return jsonb_build_object('removed', false, 'note', 'Members have their yearly service here, so it is hidden from the website instead.');
  end if;
  delete from public.pangea_locations where id = p_id;
  return jsonb_build_object('removed', true);
end $f$;

create or replace function public.centre_interest(p_id uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', i.name, 'email', i.email, 'note', i.note, 'at', i.created_at) order by i.created_at desc)
    from public.pangea_interest i where i.location_id = p_id), '[]'::jsonb);
end $f$;
revoke all on function public.centres_admin(), public.centre_save(jsonb), public.centre_remove(uuid), public.centre_interest(uuid) from public, anon;
grant execute on function public.centres_admin(), public.centre_save(jsonb), public.centre_remove(uuid), public.centre_interest(uuid) to authenticated;

notify pgrst, 'reload schema';
