-- New bookings by email too (feature booking_push): every booking that did not come from the team is also emailed to the
-- address in Messages, Booking notifications (app_settings booking_push "email"), even when nobody turned on phone notifications.
-- And a room booked on the website counts once it is paid (or held for a bank transfer check), not when the guest opens the payment
-- page, so an abandoned payment never sends a "new booking".
-- Needs booking_push.sql. Patches check they applied and skip cleanly where a database is older.

-- the email address: kept with the other booking notification settings
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.booking_push_settings_save(jsonb)') is null then raise notice 'no booking_push here, skipped'; return; end if;
  d := pg_get_functiondef('public.booking_push_settings_save(jsonb)'::regprocedure);
  if position('''email''' in d) > 0 then raise notice 'booking_push_settings_save already patched'; return; end if;
  n := replace(d, $x$'kinds', coalesce((select jsonb_agg(k) from jsonb_array_elements_text(coalesce(p->'kinds','[]'::jsonb)) k where k in ('private','stay','package','class')), '[]'::jsonb));$x$,
    $x$'kinds', coalesce((select jsonb_agg(k) from jsonb_array_elements_text(coalesce(p->'kinds','[]'::jsonb)) k where k in ('private','stay','package','class')), '[]'::jsonb),
    'email', case when coalesce(p->>'email','') ~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then lower(trim(p->>'email')) end);$x$);
  if n = d then raise notice 'booking_push_settings_save: older version, skipped'; return; end if;
  execute n;
  if position('''email''' in pg_get_functiondef('public.booking_push_settings_save(jsonb)'::regprocedure)) = 0 then raise exception 'booking_push_settings_save patch did not apply'; end if;
end $p$;

-- what the chat function gets: the email address and the sender too
do $p$
declare d text; n text;
begin
  if to_regprocedure('private.booking_push(text,uuid)') is null then return; end if;
  d := pg_get_functiondef('private.booking_push(text,uuid)'::regprocedure);
  if position('''email''' in d) > 0 then raise notice 'booking_push already patched'; return; end if;
  n := replace(d, $x$return jsonb_build_object('title', t, 'body', left(b, 180), 'tag', p_kind || '-' || p_id, 'url', url,$x$,
    $x$return jsonb_build_object('title', t, 'body', left(b, 180), 'tag', p_kind || '-' || p_id, 'url', url,
    'email', nullif(cfg->>'email', ''), 'from', (select case when s.value ~ '^\s*\{' then s.value::jsonb->>'from' end from public.app_settings s where s.key = 'welcome_email'),$x$);
  -- a paid website stay says what was paid
  n := replace(n, $x$|| coalesce(' (' || src || ')', '') || '.';
    url := '#stays';$x$, $x$|| coalesce(' (' || src || ')', '')
      || coalesce(', paid ' || to_char(nullif((select sum(x.amount_thb) from public.payments x where x.stay_id = s.id and not x.voided), 0), 'FM999,999,990') || ' THB', '') || '.';
    url := '#stays';$x$);
  if n = d then raise notice 'booking_push: older version, skipped'; return; end if;
  execute n;
  if position('''email''' in pg_get_functiondef('private.booking_push(text,uuid)'::regprocedure)) = 0 then raise exception 'booking_push patch did not apply'; end if;
end $p$;

-- the trigger: a website stay waiting for payment waits; it is sent when the payment comes in. And it is sent when an email is set,
-- even with no phone signed up for notifications.
create or replace function private.booking_push_send() returns trigger language plpgsql security definer set search_path to '' as $f$
declare k text; tok text; base text; cfg jsonb;
begin
  if private.my_staff_id() is not null then return null; end if;
  if not private.feature('booking_push', true) then return null; end if;
  if tg_table_name = 'privates' then
    if tg_op <> 'INSERT' or new.status in ('cancelled','done') or new.date < private.bkk_today() then return null; end if; k := 'book_private';
  elsif tg_table_name = 'stays' then
    if new.status = 'cancelled' or new.check_out < private.bkk_today() then return null; end if;
    if tg_op = 'INSERT' then if new.hold_until is not null then return null; end if;
    elsif not (old.hold_until is not null and new.hold_until is null) then return null; end if;
    k := 'book_stay';
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
  if coalesce(cfg->>'email', '') = '' and not exists (select 1 from public.push_subs x join public.staff st on st.id = x.staff_id where x.off_at is null and st.active
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
  if to_regclass('public.stays') is null or to_regclass('public.push_subs') is null then return; end if;
  drop trigger if exists stays_booking_push on public.stays;
  create trigger stays_booking_push after insert or update of hold_until on public.stays for each row execute function private.booking_push_send();
end $p$;

notify pgrst, 'reload schema';
