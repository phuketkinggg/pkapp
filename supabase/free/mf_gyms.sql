-- Muay Friend free: making a new gym in the shared free database (project "Muay Friend free", bnglnfdgptvnmugntiom).
-- Each gym is two schemas made from mf.template (tools/mf_template.sql): g_<slug> (the app) and g_<slug>_p (private helpers).
-- mf.make_gym() builds them, fills in the gym's starting settings, locks the plan's features (Master control),
-- makes the owner's staff record and tells the API to serve the new schema. Only the service role may call it.

-- the free plan: these features are off and locked (the gym sees them as part of the paid plans)
create or replace function mf.plan_lock(p_plan text) returns jsonb language sql immutable as $$
  select case when p_plan = 'free' then (select jsonb_object_agg(k, false) from unnest(array[
    'upgrades','shop','kitchen','motopress','stays','private_share','private_team','coach_rates','commission','fights','courses','techniques',
    'lang_my','course_offer','coaching','food_plans','order_push','shop_top','shop_modifiers','chat_report','chat_customers','job_team','email_log',
    'custview','coach_choose','partners','affiliates','cleanup','reel_covers','social_tags','social_stories','tiktok','youtube_shorts','hours',
    'actions','work','receipts_all','profile_video','receipts','accounts','investor','contacts','email','social','webpages','sitestats','chat_block',
    'ask_ai','ask_ai_web','free_packages','stay_extras','agency_mail','web_booking','web_team','receipt_send']) k)
  else '{}'::jsonb end
$$;

-- the API serves public plus every gym's app schema (never the private helpers)
create or replace function mf.serve_schemas() returns void language plpgsql security definer set search_path to '' as $$
declare l text;
begin
  select string_agg(schema_pub, ', ' order by made_at) into l from mf.gyms where status in ('ready', 'making');
  execute format('alter role authenticator set pgrst.db_schemas = %L', 'public, graphql_public' || coalesce(', ' || l, ''));
  perform pg_notify('pgrst', 'reload config');
  perform pg_notify('pgrst', 'reload schema');
end $$;

create or replace function mf.slug_for(p_name text) returns text language plpgsql stable set search_path to '' as $$
declare base text := left(trim(both '_' from regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '_', 'g')), 24); s text; n int := 1;
begin
  if base = '' or base !~ '^[a-z]' then base := 'gym_' || base; end if;
  base := left(trim(both '_' from base), 24); s := base;
  while exists (select 1 from mf.gyms where slug = s) or exists (select 1 from pg_namespace where nspname = 'g_' || s) loop
    n := n + 1; s := base || '_' || n;
  end loop;
  return s;
end $$;

create or replace function mf.make_gym(p_name text, p_owner_email text, p_owner_name text, p_owner_user uuid, p_country text default null, p_phone text default null)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare s text; sp text; sq text; r jsonb; nm text := nullif(left(btrim(coalesce(p_name, '')), 80), ''); code text;
begin
  if nm is null then raise exception 'Add the gym name.'; end if;
  if coalesce(p_owner_email, '') !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'Check the email address.'; end if;
  s := mf.slug_for(nm); sp := 'g_' || s; sq := 'g_' || s || '_p';
  insert into mf.gyms (slug, schema_pub, schema_priv, name, owner_email, plan, status) values (s, sp, sq, nm, lower(p_owner_email), 'free', 'making');
  r := mf.make_schemas(s);
  if (r->>'failed')::int > 0 then
    update mf.gyms set status = 'failed', errors = r where slug = s;
    raise exception 'The gym could not be made (% parts failed).', r->>'failed';
  end if;
  code := upper(left(replace(gen_random_uuid()::text, '-', ''), 8));
  execute format($q$insert into %I.app_settings (key, value) values
    ('acc_names', %L), ('acc_structure', %L), ('app_theme', '{}'), ('features', '{}'), ('nav_layout', '{}'), ('i18n_fix', '{}'),
    ('checkin_code', %L), ('coaching_default', 'steps,workouts,food,weight'), ('shop_vat', '{"rate":0,"included":true}'),
    ('review_message', %L), ('plan', %L)
    on conflict (key) do update set value = excluded.value$q$, sp,
    jsonb_build_object('main', nm, 'stay', 'Rooms', 'cafe', 'Cafe')::text,
    jsonb_build_object('businesses', jsonb_build_array(jsonb_build_object('name', nm, 'depts', jsonb_build_array('Gym training', 'Privates', 'Gym shop', 'Spa', 'Other'))))::text,
    code,
    'Hi {name}, thanks so much for training with us at ' || nm || '! If you have a minute, a quick Google review helps us a lot.',
    jsonb_build_object('name', 'free', 'members', 15, 'staff', 2)::text);
  execute format('insert into %I.platform (id, cfg) values (1, %L) on conflict (id) do update set cfg = excluded.cfg', sq,
    jsonb_build_object('lock', mf.plan_lock('free'), 'brand', 'muayfriend')::text);
  execute format('insert into %I.platform_owners (email) values (%L), (%L) on conflict do nothing', sq, 'hello@muayfriend.com', 'hello@phuketking.com');
  execute format('insert into %I.booking_sources (name, price_thb) values (%L, 0)', sp, 'Direct');
  execute format('insert into %I.staff (user_id, name, email, role, phone) values (%L, %L, %L, %L, %L)', sp,
    p_owner_user, coalesce(nullif(btrim(p_owner_name), ''), 'Owner'), lower(p_owner_email), 'manager', nullif(btrim(coalesce(p_phone, '')), ''));
  update mf.gyms set status = 'ready' where slug = s;
  perform mf.serve_schemas();
  return jsonb_build_object('slug', s, 'schema', sp, 'checkin_code', code);
end $f$;
revoke all on function mf.make_gym(text, text, text, uuid, text, text) from public, anon, authenticated;

-- called by the sign-up function (service role)
create or replace function public.mf_make_gym(p_name text, p_owner_email text, p_owner_name text, p_owner_user uuid, p_country text default null, p_phone text default null)
returns jsonb language sql security definer set search_path to '' as $$ select mf.make_gym(p_name, p_owner_email, p_owner_name, p_owner_user, p_country, p_phone) $$;
revoke all on function public.mf_make_gym(text, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.mf_make_gym(text, text, text, uuid, text, text) to service_role;

-- the gyms a signed-in person belongs to (as staff or as a member), so the app can open the right one
create or replace function public.mf_my_gyms() returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare g record; out jsonb := '[]'; ok boolean;
begin
  if auth.uid() is null then return '[]'; end if;
  for g in select * from mf.gyms where status = 'ready' order by name loop
    execute format('select exists (select 1 from %I.staff where user_id = $1 and active) or exists (select 1 from %I.customers where user_id = $1)', g.schema_pub, g.schema_pub) into ok using auth.uid();
    if ok then out := out || jsonb_build_array(jsonb_build_object('slug', g.slug, 'name', g.name)); end if;
  end loop;
  return out;
end $$;
revoke all on function public.mf_my_gyms() from public, anon;
grant execute on function public.mf_my_gyms() to authenticated;

-- find a gym by name (the "Which gym?" screen)
create or replace function public.mf_find_gym(q text) returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'name', name) order by name), '[]') from (
    select slug, name from mf.gyms where status = 'ready' and length(btrim(coalesce(q, ''))) >= 3 and (name ilike '%' || btrim(q) || '%' or slug = lower(btrim(q))) limit 8) x
$$;
revoke all on function public.mf_find_gym(text) from public;
grant execute on function public.mf_find_gym(text) to anon, authenticated;
