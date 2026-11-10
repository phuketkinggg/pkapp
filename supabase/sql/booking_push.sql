-- A phone notification for every new booking that did not come from the team (feature booking_push, on unless switched off):
-- a private booked by a customer in the app, on the website or from an agency email, a room booked online or from a booking
-- site calendar, a package bought online (once paid), and an agency group class guest. Not for anything a staff member adds.
-- Goes to the phones of staff who turned on notifications in the app, by default managers and front desk.
-- Settings: app_settings booking_push {"roles":[...], "kinds":["private","stay","package","class"]}.
-- Sent through the chat function (mode push), which asks public.push_targets for the text and the phones.

create or replace function private.booking_push_cfg() returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('roles', jsonb_build_array('manager','front_desk'), 'kinds', jsonb_build_array('private','stay','package','class'))
    || coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'booking_push'), '{}'::jsonb)
$f$;

create or replace function private.booking_push(p_kind text, p_id uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare cfg jsonb := private.booking_push_cfg(); roles text[]; t text; b text; url text := '#today';
  p public.privates; s public.stays; u public.purchases; a public.agency_bookings; who text; src text;
begin
  roles := array(select jsonb_array_elements_text(cfg->'roles'));
  if p_kind = 'book_private' then
    select * into p from public.privates where id = p_id; if p.id is null then return null; end if;
    who := coalesce((select c.name from public.customers c where c.id = p.customer_id and not coalesce(c.is_agency,false)), p.guest_name, 'A customer');
    src := (select x.name from public.booking_sources x where x.id = p.source_id);
    t := 'จองไพรเวทใหม่ / New private booked';
    b := who || ': ' || to_char(p.date, 'Dy DD Mon') || ' ' || to_char(p.start_time, 'HH24:MI') || coalesce(', ' || p.minutes || ' min', '')
      || coalesce(' with ' || (select st.name from public.staff st where st.id = p.coach_id), ', any coach') || coalesce(' (' || src || ')', '')
      || case when p.paid then ', paid' else '' end || '.';
    url := '#privates';
  elsif p_kind = 'book_stay' then
    select * into s from public.stays where id = p_id; if s.id is null then return null; end if;
    who := coalesce((select c.name from public.customers c where c.id = s.customer_id), 'A guest');
    src := (select x.name from public.booking_sources x where x.id = s.source_id);
    t := 'จองห้องใหม่ / New room booking';
    b := who || ': ' || coalesce((select r.name from public.rooms r where r.id = s.room_id), 'a room') || ', ' || to_char(s.check_in, 'DD Mon') || ' to ' || to_char(s.check_out, 'DD Mon')
      || coalesce(', ' || nullif(s.guests, ''), '') || coalesce(' (' || src || ')', '') || '.';
    url := '#stays';
  elsif p_kind = 'book_package' then
    select * into u from public.purchases where id = p_id; if u.id is null then return null; end if;
    who := coalesce((select c.name from public.customers c where c.id = u.customer_id), 'A customer');
    t := 'ซื้อแพ็กเกจออนไลน์ / Package bought online';
    b := who || ': ' || coalesce(u.package_name, 'a package') || case when coalesce(u.price_thb,0) > 0 then ', ' || to_char(u.price_thb, 'FM999,990') || ' THB' else '' end
      || coalesce(', starts ' || to_char(u.starts_on, 'DD Mon'), '') || '.';
    url := '#customers';
  elsif p_kind = 'book_class' then
    select * into a from public.agency_bookings where id = p_id; if a.id is null then return null; end if;
    t := 'จองคลาสใหม่ / New class booking';
    b := coalesce(a.guest_name, 'A guest') || case when a.people > 1 then ', ' || a.people || ' people' else '' end || ': ' || coalesce(to_char(a.date, 'Dy DD Mon'), '') || coalesce(' ' || left(a.time::text, 5), '')
      || coalesce(' (' || a.source_name || ')', '') || '.';
  else return null; end if;
  return jsonb_build_object('title', t, 'body', left(b, 180), 'tag', p_kind || '-' || p_id, 'url', url,
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'p256dh', x.p256dh, 'auth', x.auth))
      from public.push_subs x join public.staff st on st.id = x.staff_id where x.off_at is null and st.active and st.role = any (roles)), '[]'::jsonb));
end $f$;
revoke all on function private.booking_push(text, uuid) from public, anon, authenticated;

-- push_targets answers the booking kinds too (patched, checking it applied)
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.push_targets(text,uuid)') is null then raise notice 'no push_targets here, skipped'; return; end if;
  d := pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure);
  if position('booking_push' in d) > 0 then raise notice 'push_targets already patched'; return; end if;
  n := replace(d, $x$if p_kind <> 'arrival' then return null; end if;$x$, $x$if p_kind like 'book\_%' then return private.booking_push(p_kind, p_id); end if;
  if p_kind <> 'arrival' then return null; end if;$x$);
  if n = d then raise notice 'push_targets: older version, skipped'; return; end if;
  execute n;
  if position('booking_push' in pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure)) = 0 then raise exception 'push_targets patch did not apply'; end if;
end $p$;

-- one trigger function for the four tables: sends only for bookings not made by a staff member
create or replace function private.booking_push_send() returns trigger language plpgsql security definer set search_path to '' as $f$
declare k text; tok text; base text; cfg jsonb;
begin
  if private.my_staff_id() is not null then return null; end if;
  if not private.feature('booking_push', true) then return null; end if;
  if tg_table_name = 'privates' then
    if tg_op <> 'INSERT' or new.status in ('cancelled','done') or new.date < private.bkk_today() then return null; end if; k := 'book_private';
  elsif tg_table_name = 'stays' then
    if tg_op <> 'INSERT' or new.status = 'cancelled' or new.check_out < private.bkk_today() then return null; end if; k := 'book_stay';
  elsif tg_table_name = 'purchases' then
    if new.for_stay is not null or new.stay_id is not null or not coalesce(new.paid, false) then return null; end if;
    if tg_op = 'UPDATE' and coalesce(old.paid, false) then return null; end if;
    k := 'book_package';
  elsif tg_table_name = 'agency_bookings' then
    if tg_op <> 'INSERT' or new.kind <> 'class' or new.status = 'cancelled' then return null; end if; k := 'book_class';
  end if;
  if k is null then return null; end if;
  cfg := private.booking_push_cfg();
  if not (cfg->'kinds') ? substr(k, 6) then return null; end if;
  if not exists (select 1 from public.push_subs x join public.staff st on st.id = x.staff_id where x.off_at is null and st.active
    and st.role = any (array(select jsonb_array_elements_text(cfg->'roles')))) then return null; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  select value into base from private.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'push', 'kind', k, 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;

do $p$
begin
  if to_regclass('public.push_subs') is null then raise notice 'no push_subs here, skipped'; return; end if;
  drop trigger if exists privates_booking_push on public.privates;
  create trigger privates_booking_push after insert on public.privates for each row execute function private.booking_push_send();
  if to_regclass('public.stays') is not null then
    drop trigger if exists stays_booking_push on public.stays;
    create trigger stays_booking_push after insert on public.stays for each row execute function private.booking_push_send();
  end if;
  drop trigger if exists purchases_booking_push on public.purchases;
  create trigger purchases_booking_push after insert or update of paid on public.purchases for each row execute function private.booking_push_send();
  if to_regclass('public.agency_bookings') is not null then
    drop trigger if exists agency_bookings_push on public.agency_bookings;
    create trigger agency_bookings_push after insert on public.agency_bookings for each row execute function private.booking_push_send();
  end if;
end $p$;

-- the settings, for a manager in the app
create or replace function public.booking_push_settings_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v jsonb;
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  v := jsonb_build_object(
    'roles', coalesce((select jsonb_agg(r) from jsonb_array_elements_text(coalesce(p->'roles','[]'::jsonb)) r where r in ('manager','front_desk','resort','kitchen','coach','admin')), '[]'::jsonb),
    'kinds', coalesce((select jsonb_agg(k) from jsonb_array_elements_text(coalesce(p->'kinds','[]'::jsonb)) k where k in ('private','stay','package','class')), '[]'::jsonb));
  insert into public.app_settings(key, value) values ('booking_push', v::text) on conflict (key) do update set value = excluded.value;
  return v;
end $f$;
create or replace function public.booking_push_settings() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return private.booking_push_cfg();
end $f$;
revoke all on function public.booking_push_settings_save(jsonb) from public, anon;
revoke all on function public.booking_push_settings() from public, anon;
grant execute on function public.booking_push_settings_save(jsonb) to authenticated;
grant execute on function public.booking_push_settings() to authenticated;

notify pgrst, 'reload schema';
