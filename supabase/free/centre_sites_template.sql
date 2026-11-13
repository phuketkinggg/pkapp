delete from mf.template where name like 'centre_sites:%';
insert into mf.template (ord, phase, kind, name, sql) values (302801, 3, 'patch', 'centre_sites:302801', $TPL$alter table __P__.pangea_locations add column if not exists slug text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302802, 3, 'patch', 'centre_sites:302802', $TPL$alter table __P__.pangea_locations add column if not exists tagline text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302803, 3, 'patch', 'centre_sites:302803', $TPL$alter table __P__.pangea_locations add column if not exists about text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302804, 3, 'patch', 'centre_sites:302804', $TPL$alter table __P__.pangea_locations add column if not exists hero_url text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302805, 3, 'patch', 'centre_sites:302805', $TPL$alter table __P__.pangea_locations add column if not exists highlights jsonb not null default '[]'::jsonb;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302806, 3, 'patch', 'centre_sites:302806', $TPL$alter table __P__.pangea_locations add column if not exists whatsapp text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302807, 3, 'patch', 'centre_sites:302807', $TPL$alter table __P__.pangea_locations add column if not exists email text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302808, 3, 'patch', 'centre_sites:302808', $TPL$alter table __P__.pangea_locations add column if not exists address text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302809, 3, 'patch', 'centre_sites:302809', $TPL$alter table __P__.pangea_locations add column if not exists map_url text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302810, 3, 'patch', 'centre_sites:302810', $TPL$alter table __P__.pangea_locations add column if not exists book_url text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302811, 3, 'patch', 'centre_sites:302811', $TPL$alter table __P__.pangea_locations add column if not exists data_url text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302812, 3, 'patch', 'centre_sites:302812', $TPL$alter table __P__.pangea_locations add column if not exists published boolean not null default true;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302813, 3, 'patch', 'centre_sites:302813', $TPL$alter table __P__.pangea_locations add column if not exists updated_at timestamptz;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001501, 10, 'patch', 'centre_sites:1001501', $TPL$create unique index if not exists pangea_locations_slug on __P__.pangea_locations (lower(slug)) where slug is not null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302814, 3, 'patch', 'centre_sites:302814', $TPL$create table if not exists __P__.pangea_interest (
  id uuid primary key default gen_random_uuid(),
  location_id uuid references __P__.pangea_locations (id) on delete cascade,
  name text,
  email text not null,
  note text,
  created_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001502, 10, 'patch', 'centre_sites:1001502', $TPL$create index if not exists pangea_interest_loc on __P__.pangea_interest (location_id, created_at desc);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302815, 3, 'patch', 'centre_sites:302815', $TPL$alter table __P__.pangea_interest enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196901, 11, 'patch', 'centre_sites:1196901', $TPL$revoke all on __P__.pangea_interest from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402901, 4, 'patch', 'centre_sites:402901', $TPL$create or replace function __Q__.url_ok(u text) returns text language sql immutable as $f$
  select case when u ~ '^https://[A-Za-z0-9.-]+(/[^\s<>"]*)?$' and length(u) < 500 then u end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402902, 4, 'patch', 'centre_sites:402902', $TPL$create or replace function __P__.pangea_site() returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('centres', coalesce(jsonb_agg(jsonb_build_object('slug', l.slug, 'name', l.name, 'place', l.place, 'focus', l.focus, 'blurb', l.blurb,
      'tagline', l.tagline, 'about', l.about, 'hero', l.hero_url, 'highlights', l.highlights, 'whatsapp', l.whatsapp, 'email', l.email, 'address', l.address,
      'map', l.map_url, 'book', l.book_url, 'data', l.data_url, 'status', l.status) order by l.sort, l.name), '[]'::jsonb))
  from __P__.pangea_locations l where l.published and __Q__.feature('centre_sites', false)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196902, 11, 'patch', 'centre_sites:1196902', $TPL$revoke all on function __P__.pangea_site() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196903, 11, 'patch', 'centre_sites:1196903', $TPL$grant execute on function __P__.pangea_site() to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402903, 4, 'patch', 'centre_sites:402903', $TPL$create or replace function __P__.pangea_interest_add(p_slug text, p_name text, p_email text, p_note text) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare loc uuid; em text := lower(btrim(coalesce(p_email, '')));
begin
  if not __Q__.feature('centre_sites', false) then raise exception 'Not available.'; end if;
  if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or length(em) > 200 then raise exception 'Type your email.'; end if;
  select id into loc from __P__.pangea_locations where lower(slug) = lower(btrim(coalesce(p_slug, ''))) and published;
  if loc is null then raise exception 'That centre was not found.'; end if;
  if (select count(*) from __P__.pangea_interest where email = em and created_at > now() - interval '1 day') >= 5 then return jsonb_build_object('ok', true); end if;
  if exists (select 1 from __P__.pangea_interest where email = em and location_id = loc) then return jsonb_build_object('ok', true); end if;
  insert into __P__.pangea_interest (location_id, name, email, note) values (loc, left(nullif(btrim(coalesce(p_name, '')), ''), 120), em, left(nullif(btrim(coalesce(p_note, '')), ''), 1000));
  return jsonb_build_object('ok', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196904, 11, 'patch', 'centre_sites:1196904', $TPL$revoke all on function __P__.pangea_interest_add(text, text, text, text) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196905, 11, 'patch', 'centre_sites:1196905', $TPL$grant execute on function __P__.pangea_interest_add(text, text, text, text) to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402904, 4, 'patch', 'centre_sites:402904', $TPL$create or replace function __P__.centres_admin() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(l) - 'created_at' || jsonb_build_object('interest', (select count(*) from __P__.pangea_interest i where i.location_id = l.id),
      'members', (select count(*) from __P__.pangea_service s where s.location_id = l.id)) order by l.sort, l.name) from __P__.pangea_locations l), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402905, 4, 'patch', 'centre_sites:402905', $TPL$create or replace function __P__.centre_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare cid uuid := nullif(p->>'id', '')::uuid; sl text := lower(regexp_replace(btrim(coalesce(p->>'slug', '')), '[^a-zA-Z0-9-]+', '-', 'g')); hl jsonb := '[]'::jsonb; x jsonb;
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if btrim(coalesce(p->>'name', '')) = '' then raise exception 'Type the name.'; end if;
  sl := btrim(sl, '-');
  if sl = '' then raise exception 'Type the web address, for example phuket.'; end if;
  if sl in ('app','admin','team','book','cafe','privacy','api','www','media','icons','centre','index','404') then raise exception 'Choose another web address, % is taken.', sl; end if;
  if exists (select 1 from __P__.pangea_locations where lower(slug) = sl and id is distinct from cid) then raise exception 'Another centre already uses /%.', sl; end if;
  if jsonb_typeof(p->'highlights') = 'array' then
    for x in select * from jsonb_array_elements(p->'highlights') limit 12 loop
      if btrim(coalesce(x->>'title', '')) <> '' then hl := hl || jsonb_build_object('title', left(btrim(x->>'title'), 80), 'text', left(btrim(coalesce(x->>'text', '')), 400)); end if;
    end loop;
  end if;
  if cid is null then
    insert into __P__.pangea_locations (name, sort, status) values (left(btrim(p->>'name'), 80), coalesce(nullif(p->>'sort', '')::int, 100), 'soon') returning id into cid;
  end if;
  update __P__.pangea_locations set
    name = left(btrim(p->>'name'), 80), slug = sl, place = left(nullif(btrim(coalesce(p->>'place', '')), ''), 120), focus = left(nullif(btrim(coalesce(p->>'focus', '')), ''), 160),
    blurb = left(nullif(btrim(coalesce(p->>'blurb', '')), ''), 400), tagline = left(nullif(btrim(coalesce(p->>'tagline', '')), ''), 160), about = left(nullif(btrim(coalesce(p->>'about', '')), ''), 6000),
    hero_url = __Q__.url_ok(btrim(coalesce(p->>'hero_url', ''))), highlights = hl,
    whatsapp = left(nullif(regexp_replace(coalesce(p->>'whatsapp', ''), '[^0-9+]', '', 'g'), ''), 20), email = left(nullif(btrim(coalesce(p->>'email', '')), ''), 200),
    address = left(nullif(btrim(coalesce(p->>'address', '')), ''), 300), map_url = __Q__.url_ok(btrim(coalesce(p->>'map_url', ''))),
    book_url = __Q__.url_ok(btrim(coalesce(p->>'book_url', ''))), data_url = __Q__.url_ok(btrim(coalesce(p->>'data_url', ''))),
    status = case when p->>'status' in ('open','soon') then p->>'status' else status end, sort = coalesce(nullif(p->>'sort', '')::int, sort),
    published = coalesce((p->>'published')::boolean, published), updated_at = now()
  where id = cid;
  return cid;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402906, 4, 'patch', 'centre_sites:402906', $TPL$create or replace function __P__.centre_remove(p_id uuid) returns jsonb language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if exists (select 1 from __P__.pangea_service where location_id = p_id) then
    update __P__.pangea_locations set published = false, updated_at = now() where id = p_id;
    return jsonb_build_object('removed', false, 'note', 'Members have their yearly service here, so it is hidden from the website instead.');
  end if;
  delete from __P__.pangea_locations where id = p_id;
  return jsonb_build_object('removed', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402907, 4, 'patch', 'centre_sites:402907', $TPL$create or replace function __P__.centre_interest(p_id uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', i.name, 'email', i.email, 'note', i.note, 'at', i.created_at) order by i.created_at desc)
    from __P__.pangea_interest i where i.location_id = p_id), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196906, 11, 'patch', 'centre_sites:1196906', $TPL$revoke all on function __P__.centres_admin(), __P__.centre_save(jsonb), __P__.centre_remove(uuid), __P__.centre_interest(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196907, 11, 'patch', 'centre_sites:1196907', $TPL$grant execute on function __P__.centres_admin(), __P__.centre_save(jsonb), __P__.centre_remove(uuid), __P__.centre_interest(uuid) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'centre_sites:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
