-- Partner programme (feature: partners): levels people can apply for on the website (Affiliate, Creator, Ambassador),
-- the applications, and approving one into an affiliate with that level's share.
-- Levels live in app_settings key 'partner_levels' (Affiliates, Partner levels); without it the defaults below are used.

alter table public.affiliates add column if not exists level text;

create table if not exists public.partner_applications (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null check (char_length(name) between 2 and 80),
  email text not null check (char_length(email) <= 120),
  phone text check (char_length(phone) <= 40),
  links text check (char_length(links) <= 600),
  followers integer check (followers between 0 and 1000000000),
  avg_views integer check (avg_views between 0 and 1000000000),
  audience text check (char_length(audience) <= 200),
  offer text check (char_length(offer) <= 1200),
  level text check (char_length(level) <= 40),
  status text not null default 'new' check (status in ('new','approved','declined')),
  affiliate_id uuid references public.affiliates(id) on delete set null,
  decided_by uuid,
  decided_at timestamptz,
  note text check (char_length(note) <= 400)
);
alter table public.partner_applications enable row level security;
revoke all on public.partner_applications from anon, authenticated;

-- notices about partner applications
do $p$
declare c text; d text;
begin
  select conname, pg_get_constraintdef(oid) into c, d from pg_constraint
    where conrelid = 'public.notices'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' limit 1;
  if c is null then raise notice 'notices has no kind check';
  elsif position('''partner''' in d) > 0 then raise notice 'notices already allow partner';
  else
    execute format('alter table public.notices drop constraint %I', c);
    execute format('alter table public.notices add constraint %I %s', c,
      regexp_replace(d, '\]\)\)\)$', ', ''partner''::text])))'));
    if position('''partner''' in pg_get_constraintdef((select oid from pg_constraint where conname = c and conrelid = 'public.notices'::regclass))) = 0 then
      raise exception 'notices kind patch did not apply'; end if;
  end if;
end $p$;

-- the levels: the setting, or sensible defaults
create or replace function private.partner_levels() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce((select case when jsonb_typeof(value::jsonb) = 'array' and jsonb_array_length(value::jsonb) > 0 then value::jsonb end
                   from public.app_settings where key = 'partner_levels'),
  '[{"id":"affiliate","name":"Affiliate","pct":10,"min_followers":1000,"min_views":null,
     "who":"Anyone with a real audience: at least 1,000 followers, or a blog, YouTube channel or travel business. Past customers can always join.",
     "gets":"Your own link and QR code, and a share of what is booked through it. Paid monthly once the customer has come.",
     "gives":"Share your link where it suits your audience."},
    {"id":"creator","name":"Creator","pct":15,"min_followers":25000,"min_views":10000,
     "who":"25,000 or more followers on one platform, videos that average 10,000 or more views, and an audience that fits ours.",
     "gets":"A higher share, and a free training week.",
     "gives":"Agreed content before you come, for example 3 reels and 5 stories with tags, and footage we can use."},
    {"id":"ambassador","name":"Ambassador","pct":20,"min_followers":100000,"min_views":30000,
     "who":"100,000 or more followers and videos that average 30,000 or more views, in fitness, combat sports, travel or wellness.",
     "gets":"Our highest share, a free stay with training, and your own discount code for your followers.",
     "gives":"A full content package, for example a YouTube video, reels and stories, and a long term mention."}]'::jsonb)
$f$;

-- the website page: the levels (no money owed, nothing private)
create or replace function public.partner_levels_public() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when private.feature('partners', true) then private.partner_levels() else '[]'::jsonb end
$f$;

-- someone applies on the website
create or replace function public.partner_apply(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_name text := btrim(coalesce(p->>'name','')); v_email text := lower(btrim(coalesce(p->>'email',''))); v_id uuid; lv text;
  f int; vw int; lname text;
begin
  if not private.feature('partners', true) then raise exception 'Applications are closed right now.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 80 then raise exception 'Type your name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 120 then raise exception 'Type a real email address.'; end if;
  if char_length(btrim(coalesce(p->>'links',''))) < 4 then raise exception 'Add a link to your social media, channel or website.'; end if;
  if (select count(*) from public.partner_applications where email = v_email and created_at > now() - interval '1 day') >= 2
     or (select count(*) from public.partner_applications where created_at > now() - interval '1 hour') >= 20 then
    raise exception 'We already have your application. We will be in touch.'; end if;
  f := least(1000000000, greatest(0, round(coalesce(nullif(regexp_replace(coalesce(p->>'followers',''), '[^0-9]', '', 'g'), ''), '0')::numeric)))::int;
  vw := nullif(least(1000000000, greatest(0, round(coalesce(nullif(regexp_replace(coalesce(p->>'avg_views',''), '[^0-9]', '', 'g'), ''), '0')::numeric))), 0)::int;
  lv := (select x->>'id' from jsonb_array_elements(private.partner_levels()) x where x->>'id' = p->>'level' limit 1);
  lname := coalesce((select x->>'name' from jsonb_array_elements(private.partner_levels()) x where x->>'id' = lv limit 1), 'Partner');
  insert into public.partner_applications (name, email, phone, links, followers, avg_views, audience, offer, level)
  values (v_name, v_email, nullif(left(btrim(coalesce(p->>'phone','')),40),''), left(btrim(p->>'links'),600), f, vw,
          nullif(left(btrim(coalesce(p->>'audience','')),200),''), nullif(left(btrim(coalesce(p->>'offer','')),1200),''), lv)
  returning id into v_id;
  insert into public.notices (kind, ref_id, title, detail)
  values ('partner', v_id, lname || ' application: ' || v_name,
          to_char(f, 'FM999,999,999,990') || ' followers' || coalesce(', ' || to_char(vw, 'FM999,999,990') || ' average views', '') || '. ' || left(btrim(p->>'links'), 200) || '. See Affiliates, Applications.');
  return jsonb_build_object('ok', true);
end $f$;

-- the applications (manager)
create or replace function public.partner_apps() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see applications.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(a) order by (a.status = 'new') desc, a.created_at desc)
    from (select * from public.partner_applications order by created_at desc limit 200) a), '[]'::jsonb);
end $f$;

-- approve (makes them an affiliate with that level's share) or decline
create or replace function public.partner_app_decide(p_id uuid, p_ok boolean, p_level text default null, p_note text default null) returns uuid language plpgsql security definer set search_path to '' as $f$
declare a public.partner_applications; lv jsonb; aff uuid; code text;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can decide applications.'; end if;
  select * into a from public.partner_applications where id = p_id for update;
  if a.id is null then raise exception 'That application was not found.'; end if;
  if a.status <> 'new' then raise exception 'That application was already decided.'; end if;
  if not p_ok then
    update public.partner_applications set status = 'declined', decided_by = private.my_staff_id(), decided_at = now(), note = nullif(left(btrim(coalesce(p_note,'')),400),'') where id = a.id;
    return null;
  end if;
  select x into lv from jsonb_array_elements(private.partner_levels()) x where x->>'id' = coalesce(p_level, a.level) limit 1;
  if lv is null then raise exception 'Choose a level.'; end if;
  select id into aff from public.affiliates where lower(email) = a.email limit 1;
  if aff is null then
    aff := public.affiliate_save(jsonb_build_object('name', a.name, 'email', a.email, 'phone', a.phone, 'pct', lv->>'pct', 'active', true,
      'note', left(concat_ws(E'\n', lv->>'name' || ' partner.', a.links, nullif(p_note,'')), 400)));
  else
    update public.affiliates set pct = (lv->>'pct')::numeric, active = true where id = aff;
  end if;
  update public.affiliates set level = lv->>'id' where id = aff;
  update public.partner_applications set status = 'approved', level = lv->>'id', affiliate_id = aff, decided_by = private.my_staff_id(), decided_at = now(),
    note = nullif(left(btrim(coalesce(p_note,'')),400),'') where id = a.id;
  update public.notices set done_at = now() where kind = 'partner' and ref_id = a.id and done_at is null;
  return aff;
end $f$;

revoke all on function private.partner_levels() from public, anon, authenticated;
revoke all on function public.partner_apps(), public.partner_app_decide(uuid, boolean, text, text) from public, anon;
grant execute on function public.partner_apps(), public.partner_app_decide(uuid, boolean, text, text) to authenticated;
grant execute on function public.partner_levels_public(), public.partner_apply(jsonb) to anon, authenticated;
notify pgrst, 'reload schema';
