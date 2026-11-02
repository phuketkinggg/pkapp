-- Muay Friend billing: paid plans bought in the app through Stripe (edge function mf-billing in the free project).
-- A gym's plan decides which features are locked (Master control) and its member and staff limits.
-- Stripe ids are kept on mf.gyms; Stripe's webhook signing secret and the admin key are kept in mf.cfg (never in code).
alter table mf.gyms add column if not exists stripe_customer text;
alter table mf.gyms add column if not exists stripe_sub text;
alter table mf.gyms add column if not exists plan_cycle text;
alter table mf.gyms add column if not exists plan_status text;
alter table mf.gyms add column if not exists paid_until timestamptz;
insert into mf.cfg (key, value) values ('admin_key', to_jsonb(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))) on conflict (key) do nothing;

-- what each plan locks (from the agreed feature table: Free, Gym and Gym Plus, Camp, Master)
create or replace function mf.plan_lock(p_plan text) returns jsonb language sql immutable as $$
  select coalesce((select jsonb_object_agg(k, false) from unnest(case p_plan
    when 'free' then array[
      'upgrades','shop','kitchen','motopress','stays','private_share','private_team','coach_rates','commission','fights','courses','techniques',
      'lang_my','course_offer','coaching','food_plans','order_push','shop_top','shop_modifiers','chat_report','chat_customers','job_team','email_log',
      'custview','coach_choose','partners','affiliates','cleanup','reel_covers','social_tags','social_stories','tiktok','youtube_shorts','hours',
      'actions','work','receipts_all','profile_video','receipts','accounts','investor','contacts','email','social','webpages','sitestats','chat_block',
      'ask_ai','ask_ai_web','free_packages','stay_extras','agency_mail','web_booking','web_team','receipt_send']
    when 'gym' then array[
      'kitchen','order_push','agency_mail','private_team','job_team','work','investor','lang_my','coaching','courses','course_offer','techniques',
      'fights','contacts','social','social_tags','social_stories','tiktok','youtube_shorts','reel_covers','partners','affiliates',
      'stays','motopress','food_plans','stay_extras','ask_ai','ask_ai_web','cleanup']
    when 'gym_plus' then array[
      'kitchen','order_push','agency_mail','private_team','job_team','work','investor','lang_my','coaching','courses','course_offer','techniques',
      'fights','contacts','social','social_tags','social_stories','tiktok','youtube_shorts','reel_covers','partners','affiliates',
      'stays','motopress','food_plans','stay_extras','ask_ai','ask_ai_web','cleanup']
    when 'camp' then array['stays','motopress','food_plans','stay_extras','ask_ai','ask_ai_web','cleanup']
    else array[]::text[] end) k), '{}'::jsonb)
$$;

create or replace function mf.plan_limits(p_plan text) returns jsonb language sql immutable as $$
  select case p_plan
    when 'gym' then '{"members":30,"staff":6}'::jsonb
    when 'gym_plus' then '{"members":100,"staff":6}'::jsonb
    when 'camp' then '{"members":150,"staff":15}'::jsonb
    when 'master' then '{"members":150,"staff":null}'::jsonb
    else '{"members":15,"staff":2}'::jsonb end
$$;

-- put a gym on a plan: locks, limits, and the plan record
create or replace function mf.set_plan(p_slug text, p_plan text, p_info jsonb default '{}') returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare g record; cfg jsonb; pl text := case when p_plan in ('free','gym','gym_plus','camp','master') then p_plan else 'free' end;
begin
  select * into g from mf.gyms where slug = p_slug;
  if g is null then raise exception 'No gym %', p_slug; end if;
  execute format('select coalesce(cfg, ''{}''::jsonb) from %I.platform where id = 1', g.schema_priv) into cfg;
  cfg := coalesce(cfg, '{}'::jsonb) || jsonb_build_object('lock', mf.plan_lock(pl));
  execute format('insert into %I.platform (id, cfg) values (1, %L) on conflict (id) do update set cfg = excluded.cfg', g.schema_priv, cfg::text);
  execute format('insert into %I.app_settings (key, value) values (''plan'', %L) on conflict (key) do update set value = excluded.value', g.schema_pub,
    (jsonb_build_object('name', pl, 'cycle', p_info->>'cycle', 'status', p_info->>'status') || mf.plan_limits(pl))::text);
  update mf.gyms set plan = pl,
    plan_cycle = coalesce(p_info->>'cycle', plan_cycle), plan_status = coalesce(p_info->>'status', plan_status),
    stripe_customer = coalesce(p_info->>'customer', stripe_customer), stripe_sub = coalesce(p_info->>'sub', stripe_sub),
    paid_until = coalesce((p_info->>'paid_until')::timestamptz, paid_until)
  where slug = p_slug;
  return jsonb_build_object('slug', p_slug, 'plan', pl);
end $f$;
revoke all on function mf.set_plan(text, text, jsonb) from public, anon, authenticated;

-- for the billing function (service role only)
create or replace function public.mf_billing_gym(p_slug text, p_user uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare g record; ok boolean;
begin
  select * into g from mf.gyms where slug = p_slug and status = 'ready';
  if g is null then return null; end if;
  execute format('select exists (select 1 from %I.staff where user_id = $1 and role = ''manager'' and active)', g.schema_pub) into ok using p_user;
  return jsonb_build_object('slug', g.slug, 'name', g.name, 'owner_email', g.owner_email, 'plan', g.plan, 'cycle', g.plan_cycle,
    'status', g.plan_status, 'customer', g.stripe_customer, 'sub', g.stripe_sub, 'manager', ok);
end $f$;
create or replace function public.mf_billing_set(p_slug text, p_plan text, p_info jsonb) returns jsonb language sql security definer set search_path to '' as $$ select mf.set_plan(p_slug, p_plan, p_info) $$;
create or replace function public.mf_billing_cfg(p_key text) returns text language sql stable security definer set search_path to '' as $$
  select value #>> '{}' from mf.cfg where key = p_key and key in ('stripe_whsec', 'admin_key') $$;
create or replace function public.mf_billing_cfg_set(p_key text, p_value text) returns void language sql security definer set search_path to '' as $$
  insert into mf.cfg (key, value) values (p_key, to_jsonb(p_value)) on conflict (key) do update set value = excluded.value $$;
create or replace function public.mf_billing_by_sub(p_sub text, p_customer text) returns text language sql stable security definer set search_path to '' as $$
  select slug from mf.gyms where (p_sub is not null and stripe_sub = p_sub) or (p_customer is not null and stripe_customer = p_customer) order by stripe_sub = p_sub desc nulls last limit 1 $$;
revoke all on function public.mf_billing_gym(text, uuid), public.mf_billing_set(text, text, jsonb), public.mf_billing_cfg(text), public.mf_billing_cfg_set(text, text), public.mf_billing_by_sub(text, text) from public, anon, authenticated;
grant execute on function public.mf_billing_gym(text, uuid), public.mf_billing_set(text, text, jsonb), public.mf_billing_cfg(text), public.mf_billing_cfg_set(text, text), public.mf_billing_by_sub(text, text) to service_role;
