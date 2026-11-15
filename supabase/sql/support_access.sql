-- Tech support access: the app's own support team (private.platform_owners) can open any business's back office to help,
-- without the business making them a login. They show in Staff as "Tech support" so the business always sees them,
-- the business can remove them, and turning off the feature support_access removes them and keeps them out.

alter table public.staff add column if not exists support boolean not null default false;

-- signed in as a support person: join this business's team as Tech support (a manager), or come back if removed earlier
create or replace function public.support_join() returns jsonb language plpgsql security definer set search_path to '' as $f$
declare em text := lower(coalesce(auth.jwt()->>'email', '')); uid uuid := auth.uid(); sid uuid; was_support boolean; c1 text; c2 text;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  if not private.is_platform_owner() then raise exception 'Only the app support team can do this.'; end if;
  if not private.feature('support_access', true) then raise exception 'This business has turned off tech support access.'; end if;
  select id, support into sid, was_support from public.staff where user_id = uid limit 1;
  if sid is not null and not was_support then return jsonb_build_object('ok', true, 'staff', true); end if;
  -- the staff guard only lets managers add managers: this is the system adding support, so it runs as the system
  c1 := current_setting('request.jwt.claims', true); c2 := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claims', '{}', true); perform set_config('request.jwt.claim.sub', '', true);
  if sid is not null then
    update public.staff set active = true, role = 'manager' where id = sid;
  else
    insert into public.staff (user_id, name, email, role, active, also_coach, web_show, privates_off, support)
      values (uid, 'Tech support', nullif(em, ''), 'manager', true, false, false, true, true);
    update public.staff set user_id = uid where support and user_id is null and lower(email) = em;
  end if;
  perform set_config('request.jwt.claims', coalesce(c1, ''), true); perform set_config('request.jwt.claim.sub', coalesce(c2, ''), true);
  return jsonb_build_object('ok', true);
end $f$;

-- a support person leaves when the job is done
create or replace function public.support_leave() returns void language plpgsql security definer set search_path to '' as $f$
declare uid uuid := auth.uid(); c1 text := current_setting('request.jwt.claims', true); c2 text := current_setting('request.jwt.claim.sub', true);
begin
  if uid is null then return; end if;
  perform set_config('request.jwt.claims', '{}', true); perform set_config('request.jwt.claim.sub', '', true);
  delete from public.staff where user_id = uid and support;
  perform set_config('request.jwt.claims', coalesce(c1, ''), true); perform set_config('request.jwt.claim.sub', coalesce(c2, ''), true);
end $f$;

-- the business turns tech support access off: support people are taken off the team straight away
create or replace function private.support_off() returns trigger language plpgsql security definer set search_path to '' as $f$
declare c1 text; c2 text;
begin
  if new.key = 'features' and not private.feature('support_access', true) and exists (select 1 from public.staff where support) then
    c1 := current_setting('request.jwt.claims', true); c2 := current_setting('request.jwt.claim.sub', true);
    perform set_config('request.jwt.claims', '{}', true); perform set_config('request.jwt.claim.sub', '', true);
    delete from public.staff where support;
    perform set_config('request.jwt.claims', coalesce(c1, ''), true); perform set_config('request.jwt.claim.sub', coalesce(c2, ''), true);
  end if;
  return new;
end $f$;
drop trigger if exists support_off on public.app_settings;
create trigger support_off after insert or update on public.app_settings for each row execute function private.support_off();

revoke all on function public.support_join() from public, anon;
revoke all on function public.support_leave() from public, anon;
revoke all on function private.support_off() from public, anon, authenticated;
grant execute on function public.support_join() to authenticated;
grant execute on function public.support_leave() to authenticated;

notify pgrst, 'reload schema';
