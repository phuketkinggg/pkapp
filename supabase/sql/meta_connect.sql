-- Connect Facebook and Instagram yourself (feature meta_connect): a manager signs in with Meta in the app, picks the
-- Facebook page, and the page (with the Instagram business account linked to it) is used for Messages and Social media.
-- The page token is kept here in the private schema, never shown in the app. Where the META_PAGE_TOKEN secret is also set,
-- the page connected in the app is used first.
-- The Meta app ID and sign in configuration IDs come from the secrets META_APP_ID, META_FB_CONFIG and META_WA_CONFIG
-- (set once for everyone using the app), or are typed in by a manager (app_settings wa_meta: app_id, config_id, fb_config_id).
-- Needs whatsapp_inbox.sql (wa_meta). Where it is missing (an older demo) the save function skips cleanly.

create table if not exists private.meta_link (
  id boolean primary key default true check (id),
  page_id text, page_name text, token text, ig_id text, ig_name text,
  pages jsonb,            -- while choosing: the pages the sign in can see, with their tokens (cleared once one is picked)
  connected_at timestamptz, updated_at timestamptz not null default now()
);
revoke all on private.meta_link from public, anon, authenticated;

-- for the meta and social functions only
create or replace function public.meta_link_get() returns jsonb language sql stable security definer set search_path='' as $f$
  select coalesce((select jsonb_build_object('page_id', page_id, 'page_name', page_name, 'token', token, 'ig_id', ig_id, 'ig_name', ig_name, 'pages', pages, 'at', connected_at) from private.meta_link), '{}'::jsonb)
$f$;
create or replace function public.meta_link_set(p jsonb) returns void language plpgsql security definer set search_path='' as $f$
begin
  insert into private.meta_link(id) values (true) on conflict (id) do nothing;
  update private.meta_link set
    page_id = case when p ? 'page_id' then nullif(p->>'page_id','') else page_id end,
    page_name = case when p ? 'page_name' then nullif(p->>'page_name','') else page_name end,
    token = case when p ? 'token' then nullif(p->>'token','') else token end,
    ig_id = case when p ? 'ig_id' then nullif(p->>'ig_id','') else ig_id end,
    ig_name = case when p ? 'ig_name' then nullif(p->>'ig_name','') else ig_name end,
    pages = case when p ? 'pages' then case when jsonb_typeof(p->'pages') = 'array' then p->'pages' end else pages end,
    connected_at = case when p ? 'page_id' and nullif(p->>'page_id','') is not null then now() when p ? 'page_id' then null else connected_at end,
    updated_at = now();
end $f$;
revoke all on function public.meta_link_get() from public, anon, authenticated;
revoke all on function public.meta_link_set(jsonb) from public, anon, authenticated;
grant execute on function public.meta_link_get() to service_role;
grant execute on function public.meta_link_set(jsonb) to service_role;

-- the Facebook sign in configuration ID typed in by a manager (when the META_FB_CONFIG secret is not set), kept with the WhatsApp one
do $p$
begin
  if to_regprocedure('public.wa_meta_save(text,text)') is null then raise notice 'no wa_meta here, meta_login_save skipped'; return; end if;
  execute $q$
create or replace function public.meta_login_save(p_app_id text, p_fb_config text) returns void language plpgsql security definer set search_path='' as $f$
declare v jsonb;
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can connect Facebook and Instagram.'; end if;
  if coalesce(p_app_id,'') !~ '^\d{6,}$' then raise exception 'The Meta app ID is a long number.'; end if;
  if coalesce(p_fb_config,'') !~ '^\d{6,}$' then raise exception 'The configuration ID is a long number.'; end if;
  select case when value ~ '^\s*\{' then value::jsonb end into v from public.app_settings where key = 'wa_meta';
  v := coalesce(v, '{}'::jsonb) || jsonb_build_object('app_id', p_app_id, 'fb_config_id', p_fb_config);
  insert into public.app_settings(key, value) values ('wa_meta', v::text) on conflict (key) do update set value = excluded.value;
end $f$;
$q$;
  revoke all on function public.meta_login_save(text, text) from public, anon;
  grant execute on function public.meta_login_save(text, text) to authenticated;
end $p$;

-- wa_meta_save keeps the Facebook configuration ID (patched, checking it applied)
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.wa_meta_save(text,text)') is null then return; end if;
  d := pg_get_functiondef('public.wa_meta_save(text,text)'::regprocedure);
  if position('fb_config_id' in d) > 0 then raise notice 'wa_meta_save already patched'; return; end if;
  n := replace(d, $x$values ('wa_meta', jsonb_build_object('app_id', p_app_id, 'config_id', p_config_id)::text)
    on conflict (key) do update set value = excluded.value;$x$,
    $x$values ('wa_meta', jsonb_build_object('app_id', p_app_id, 'config_id', p_config_id)::text)
    on conflict (key) do update set value = (coalesce((select case when s.value ~ '^\s*\{' then s.value::jsonb end from public.app_settings s where s.key = 'wa_meta'), '{}'::jsonb)
      || jsonb_build_object('app_id', p_app_id, 'config_id', p_config_id))::text; -- keeps fb_config_id$x$);
  if n = d then raise notice 'wa_meta_save: older version, skipped'; return; end if;
  execute n;
  if position('fb_config_id' in pg_get_functiondef('public.wa_meta_save(text,text)'::regprocedure)) = 0 then raise exception 'wa_meta_save patch did not apply'; end if;
end $p$;

notify pgrst, 'reload schema';
