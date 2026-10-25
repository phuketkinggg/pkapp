-- YouTube Shorts as a place to post reels (and trial reels) from Social media.
-- The owner connects the channel once (Google sign in); the refresh token is kept in private.kv, never sent to the app.

-- posts can go to YouTube too (a video only)
do $$ declare s text;
begin
  s := pg_get_functiondef('public.social_save(jsonb)'::regprocedure);
  if s not like '%youtube%' then
    s := replace(s, $a$where x in ('facebook','instagram');$a$, $a$where x in ('facebook','instagram','youtube');$a$);
    s := replace(s, $a$  if v_kind = 'trial' then v_pl := array['instagram']; end if;$a$,
      $a$  if v_kind = 'trial' then v_pl := array['instagram'] || case when 'youtube' = any(v_pl) then array['youtube'] else '{}'::text[] end; end if;$a$);
    s := replace(s, $a$    if cardinality(v_pl) = 0 then raise exception 'Choose Facebook, Instagram or both.'; end if;$a$,
      $a$    if cardinality(v_pl) = 0 then raise exception 'Choose where to post.'; end if;
    if 'youtube' = any(v_pl) and v_vid = 0 then raise exception 'YouTube Shorts needs a video.'; end if;$a$);
    if (length(s) - length(replace(s, 'youtube', ''))) / 7 < 4 then raise exception 'social_save patch did not apply'; end if;
    execute s;
  end if;
end $$;

-- the channel link (server only)
create or replace function public.yt_get() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select value::jsonb from private.kv where key = 'youtube'), '{}'::jsonb)
$$;
create or replace function public.yt_set(p jsonb) returns void language sql security definer set search_path to '' as $$
  insert into private.kv (key, value) values ('youtube', p::text) on conflict (key) do update set value = excluded.value
$$;
-- a one time code for the Google sign in (10 minutes)
create or replace function public.yt_state_new() returns text language plpgsql security definer set search_path to '' as $$
declare s text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only the owner or an admin can connect YouTube.'; end if;
  insert into private.kv (key, value) values ('youtube_state', jsonb_build_object('s', s, 'until', now() + interval '10 minutes')::text)
    on conflict (key) do update set value = excluded.value;
  return s;
end $$;
create or replace function public.yt_state_ok(p_s text) returns boolean language plpgsql security definer set search_path to '' as $$
declare v jsonb := (select value::jsonb from private.kv where key = 'youtube_state');
begin
  if v is null or v->>'s' is distinct from p_s or (v->>'until')::timestamptz < now() then return false; end if;
  delete from private.kv where key = 'youtube_state';
  return true;
end $$;
-- the app: is it connected, and disconnect
create or replace function public.yt_status() returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Not allowed.'; end if;
  return jsonb_build_object('connected', public.yt_get() ? 'refresh', 'channel', public.yt_get()->>'channel');
end $$;
create or replace function public.yt_disconnect() returns void language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Not allowed.'; end if;
  delete from private.kv where key = 'youtube';
end $$;
revoke all on function public.yt_get() from public, anon, authenticated;
revoke all on function public.yt_set(jsonb) from public, anon, authenticated;
revoke all on function public.yt_state_ok(text) from public, anon, authenticated;
revoke all on function public.yt_state_new() from public, anon;
revoke all on function public.yt_status() from public, anon;
revoke all on function public.yt_disconnect() from public, anon;
grant execute on function public.yt_get() to service_role;
grant execute on function public.yt_set(jsonb) to service_role;
grant execute on function public.yt_state_ok(text) to service_role;
grant execute on function public.yt_state_new() to authenticated;
grant execute on function public.yt_status() to authenticated;
grant execute on function public.yt_disconnect() to authenticated;
