-- The owner (feature owner_lock): one person is the owner of the business (app_settings owner_staff: their staff id).
-- Only the owner can change the deep settings (features, money settings, accounts set up, health record owners, affiliate food rule)
-- and the managers and admins (their role, access, sign in and PIN). Other managers run the business day to day as before.
-- Not set, or switched off: every manager can do everything, as before.
-- Recovery codes: the owner makes a set of one-time codes (only their hashes are kept). If the owner is ever locked out,
-- a code plus the owner's email sets a new password and puts the owner back as an active manager (edge function owner-recover).

create or replace function private.biz_owner_id() returns uuid
language plpgsql stable security definer set search_path to '' as $$
declare v text; id uuid;
begin
  v := btrim(coalesce((select value from public.app_settings where key = 'owner_staff'), ''), '" ');
  if v !~ '^[0-9a-f-]{36}$' then return null; end if;
  select s.id into id from public.staff s where s.id = v::uuid;
  return id;
end $$;

create or replace function private.owner_locked() returns boolean
language sql stable security definer set search_path to '' as $$
  select private.feature('owner_lock', true) and private.biz_owner_id() is not null
$$;

create or replace function private.is_biz_owner() returns boolean
language sql stable security definer set search_path to '' as $$
  select private.my_staff_id() is not null and private.my_staff_id() = private.biz_owner_id()
$$;

-- deep settings: only the owner, once there is one
create or replace function private.owner_settings_guard() returns trigger
language plpgsql security definer set search_path to '' as $$
declare k text := coalesce(new.key, old.key);
begin
  if (select auth.uid()) is null then return coalesce(new, old); end if;
  if k = 'owner_staff' and coalesce(current_setting('pk.owner_set', true), '') <> '1' then raise exception 'Use Settings, General, Owner to change the owner.'; end if;
  if k in ('features', 'pay_extras', 'acc_structure', 'acc_names', 'health_keepers', 'aff_food') and private.owner_locked() and not private.is_biz_owner() then
    raise exception 'Only the owner can change this setting.'; end if;
  return coalesce(new, old);
end $$;
drop trigger if exists zz_owner_settings on public.app_settings;
create trigger zz_owner_settings before insert or update or delete on public.app_settings for each row execute function private.owner_settings_guard();

-- managers and admins: only the owner changes their role, access, sign in, PIN, pay share or whether they are active; nobody else touches the owner
create or replace function private.owner_staff_guard() returns trigger
language plpgsql security definer set search_path to '' as $$
declare me uuid := private.my_staff_id(); o uuid;
begin
  if (select auth.uid()) is null or not private.owner_locked() or private.is_biz_owner() or coalesce(current_setting('pk.owner_recover', true), '') = '1' then return coalesce(new, old); end if;
  o := private.biz_owner_id();
  if coalesce(new.id, old.id) = o then raise exception 'Only the owner can change the owner.'; end if;
  if tg_op = 'DELETE' then
    if old.role in ('manager', 'admin') then raise exception 'Only the owner can remove managers and admins.'; end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    if new.role in ('manager', 'admin') then raise exception 'Only the owner can add managers and admins.'; end if;
    return new;
  end if;
  if new.role is distinct from old.role and (new.role in ('manager', 'admin') or old.role in ('manager', 'admin')) then raise exception 'Only the owner can make or change managers and admins.'; end if;
  if old.role in ('manager', 'admin') and (new.access is distinct from old.access or new.active is distinct from old.active or new.email is distinct from old.email
      or new.user_id is distinct from old.user_id or new.commission_pct is distinct from old.commission_pct or (new.pin_hash is distinct from old.pin_hash and old.id <> me)) then
    raise exception 'Only the owner can change managers and admins.'; end if;
  return new;
end $$;
drop trigger if exists zz_owner_staff on public.staff;
create trigger zz_owner_staff before insert or update or delete on public.staff for each row execute function private.owner_staff_guard();

-- who the owner is, and what this person may do
create or replace function public.owner_info() returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare o uuid := private.biz_owner_id();
begin
  if private.my_staff_id() is null then raise exception 'Staff only.'; end if;
  return jsonb_build_object('on', private.feature('owner_lock', true), 'owner', (select name from public.staff where id = o), 'me', private.is_biz_owner(),
    'locked', private.owner_locked(), 'codes_left', case when private.is_biz_owner() then (select count(*) from private.owner_codes where used_at is null) end,
    'codes_made', case when private.is_biz_owner() then (select max(created_at) from private.owner_codes) end);
end $$;

-- make the owner: the first time any manager (usually the person who set the business up); after that only the owner can hand it over
create or replace function public.owner_set(p_staff uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare s public.staff;
begin
  if private.biz_owner_id() is not null and not private.is_biz_owner() then raise exception 'Only the owner can hand over the business.'; end if;
  if private.biz_owner_id() is null and coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select * into s from public.staff where id = p_staff and active and role = 'manager' and user_id is not null;
  if s.id is null then raise exception 'The owner must be an active manager with a sign in.'; end if;
  perform set_config('pk.owner_set', '1', true);
  insert into public.app_settings (key, value) values ('owner_staff', s.id::text) on conflict (key) do update set value = excluded.value, updated_at = now();
  delete from private.owner_codes where true;  -- a new owner makes their own recovery codes
end $$;

create table if not exists private.owner_codes (id uuid primary key default gen_random_uuid(), code_hash text not null, created_at timestamptz not null default now(), used_at timestamptz);
create table if not exists private.owner_code_tries (at timestamptz not null default now(), ok boolean not null default false);

-- the owner makes a new set of 8 recovery codes; the old ones stop working. The codes are shown once, only their hashes are kept.
create or replace function public.owner_recovery_codes() returns text[]
language plpgsql security definer set search_path to '' as $$
declare out text[] := '{}'; c text; i int; abc text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea;
begin
  if not private.is_biz_owner() then raise exception 'Only the owner can make recovery codes.'; end if;
  delete from private.owner_codes where true;
  for i in 1..8 loop
    b := extensions.gen_random_bytes(16); c := '';
    for j in 0..15 loop c := c || substr(abc, (get_byte(b, j) % 32) + 1, 1); if j in (3, 7, 11) then c := c || '-'; end if; end loop;
    insert into private.owner_codes (code_hash) values (extensions.crypt(c, extensions.gen_salt('bf', 10)));
    out := out || c;
  end loop;
  return out;
end $$;

-- for the edge function only (it runs as the service role, so the guards above do not apply): checks the owner's email and a code (5 tries an hour, 15 a day), uses up the code,
-- puts the owner back as an active manager, and gives back the owner's sign in id
create or replace function public.owner_recover_check(p_email text, p_code text) returns uuid
language plpgsql security definer set search_path to '' as $$
declare o public.staff; k record; code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if (select count(*) from private.owner_code_tries where at > now() - interval '1 hour' and not ok) >= 5
     or (select count(*) from private.owner_code_tries where at > now() - interval '1 day' and not ok) >= 15 then
    raise exception 'Too many tries. Wait an hour and try again.'; end if;
  select * into o from public.staff where id = private.biz_owner_id();
  if length(code) = 16 then code := substr(code, 1, 4) || '-' || substr(code, 5, 4) || '-' || substr(code, 9, 4) || '-' || substr(code, 13, 4); end if;
  if o.id is not null and o.user_id is not null and lower(btrim(coalesce(p_email, ''))) = lower(coalesce(o.email, (select email from auth.users where id = o.user_id))) then
    for k in select * from private.owner_codes where used_at is null loop
      if extensions.crypt(code, k.code_hash) = k.code_hash then
        update private.owner_codes set used_at = now() where id = k.id;
        insert into private.owner_code_tries (ok) values (true);
        perform set_config('pk.owner_recover', '1', true);
        update public.staff set active = true, role = 'manager' where id = o.id;
        return o.user_id;
      end if;
    end loop;
  end if;
  insert into private.owner_code_tries (ok) values (false);  -- kept: a wrong try is counted, so no exception here
  return null;
end $$;

revoke all on function private.biz_owner_id(), private.owner_locked(), private.is_biz_owner() from public, anon;
grant execute on function private.biz_owner_id(), private.owner_locked(), private.is_biz_owner() to authenticated;
revoke all on function public.owner_recover_check(text, text) from public, anon, authenticated;
grant execute on function public.owner_recover_check(text, text) to service_role;
revoke all on function public.owner_info(), public.owner_set(uuid), public.owner_recovery_codes() from public, anon;
grant execute on function public.owner_info(), public.owner_set(uuid), public.owner_recovery_codes() to authenticated;
