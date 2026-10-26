-- TikTok as a place to send reels from Social media. The video goes to the TikTok inbox as a draft:
-- the owner opens TikTok, adds a sound and the caption, and posts. Feature switch: tiktok.
-- The owner connects the account once (TikTok sign in); the refresh token is kept in private.kv, never sent to the app.

-- posts can go to TikTok too (a video only)
do $$ declare s text;
begin
  s := pg_get_functiondef('public.social_save(jsonb)'::regprocedure);
  if s like '%tiktok%' then return; end if;
  s := replace(s, $a$where x in ('facebook','instagram','youtube');$a$, $a$where x in ('facebook','instagram','youtube','tiktok');$a$);
  s := replace(s, $a$then array['youtube'] else '{}'::text[] end; end if;$a$,
    $a$then array['youtube'] else '{}'::text[] end || case when 'tiktok' = any(v_pl) then array['tiktok'] else '{}'::text[] end; end if;$a$);
  s := replace(s, $a$    if 'youtube' = any(v_pl) and v_vid = 0 then raise exception 'YouTube Shorts needs a video.'; end if;$a$,
    $a$    if 'youtube' = any(v_pl) and v_vid = 0 then raise exception 'YouTube Shorts needs a video.'; end if;
    if 'tiktok' = any(v_pl) and v_vid = 0 then raise exception 'TikTok needs a video.'; end if;$a$);
  if (length(s) - length(replace(s, 'tiktok', ''))) / 6 < 4 then raise notice 'social_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;

-- the account link (server only)
create or replace function public.tt_get() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select value::jsonb from private.kv where key = 'tiktok'), '{}'::jsonb)
$$;
create or replace function public.tt_set(p jsonb) returns void language sql security definer set search_path to '' as $$
  insert into private.kv (key, value) values ('tiktok', p::text) on conflict (key) do update set value = excluded.value
$$;
-- a one time code for the TikTok sign in (10 minutes)
create or replace function public.tt_state_new() returns text language plpgsql security definer set search_path to '' as $$
declare s text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only the owner or an admin can connect TikTok.'; end if;
  insert into private.kv (key, value) values ('tiktok_state', jsonb_build_object('s', s, 'until', now() + interval '10 minutes')::text)
    on conflict (key) do update set value = excluded.value;
  return s;
end $$;
create or replace function public.tt_state_ok(p_s text) returns boolean language plpgsql security definer set search_path to '' as $$
declare v jsonb := (select value::jsonb from private.kv where key = 'tiktok_state');
begin
  if v is null or v->>'s' is distinct from p_s or (v->>'until')::timestamptz < now() then return false; end if;
  delete from private.kv where key = 'tiktok_state';
  return true;
end $$;
create or replace function public.tt_disconnect() returns void language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Not allowed.'; end if;
  delete from private.kv where key = 'tiktok';
end $$;
revoke all on function public.tt_get() from public, anon, authenticated;
revoke all on function public.tt_set(jsonb) from public, anon, authenticated;
revoke all on function public.tt_state_ok(text) from public, anon, authenticated;
revoke all on function public.tt_state_new() from public, anon;
revoke all on function public.tt_disconnect() from public, anon;
grant execute on function public.tt_get() to service_role;
grant execute on function public.tt_set(jsonb) to service_role;
grant execute on function public.tt_state_ok(text) to service_role;
grant execute on function public.tt_state_new() to authenticated;
grant execute on function public.tt_disconnect() to authenticated;
