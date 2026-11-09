-- A coach gets a phone notification when a private is booked with them, moved, or cancelled (feature coach_push, on unless
-- switched off). Only phones where the coach turned on notifications in the app. Not when the coach booked or changed it themselves.
-- Sent through the chat function (mode push), which asks public.push_targets for the text and the phones.

create or replace function private.private_push(p_kind text, p_id uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare p public.privates; who text; t text; b text;
begin
  select * into p from public.privates where id = p_id;
  if p.id is null or p.coach_id is null then return null; end if;
  who := coalesce((select c.name from public.customers c where c.id = p.customer_id and not coalesce(c.is_agency,false)), p.guest_name, (select c.name from public.customers c where c.id = p.customer_id), 'a customer');
  b := to_char(p.date, 'Dy DD Mon') || ' ' || to_char(p.start_time, 'HH24:MI') || coalesce(', ' || p.minutes || ' min', '') || ', ' || who;
  t := case p_kind when 'private_new' then 'ไพรเวทใหม่ / New private' when 'private_move' then 'ไพรเวทย้ายเวลา / Private moved' else 'ไพรเวทยกเลิก / Private cancelled' end;
  return jsonb_build_object('title', t, 'body', left(b, 180), 'tag', 'private-' || p.id, 'url', '#mine',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from public.push_subs s join public.staff st on st.id = s.staff_id where s.off_at is null and st.active and st.id = p.coach_id), '[]'::jsonb));
end $f$;
revoke all on function private.private_push(text, uuid) from public, anon, authenticated;

-- push_targets answers the private kinds too (patched, checking it applied)
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.push_targets(text,uuid)') is null then raise notice 'no push_targets here, skipped'; return; end if;
  d := pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure);
  if position('private_push' in d) > 0 then raise notice 'push_targets already patched'; return; end if;
  n := replace(d, $x$if p_kind <> 'arrival' then return null; end if;$x$, $x$if p_kind in ('private_new','private_move','private_off') then return private.private_push(p_kind, p_id); end if;
  if p_kind <> 'arrival' then return null; end if;$x$);
  if n = d then raise notice 'push_targets: older version, skipped'; return; end if;
  execute n;
  if position('private_push' in pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure)) = 0 then raise exception 'push_targets patch did not apply'; end if;
end $p$;

create or replace function private.private_coach_push() returns trigger language plpgsql security definer set search_path to '' as $f$
declare k text; tok text; base text;
begin
  if new.coach_id is null or new.date < private.bkk_today() then return null; end if;
  if not private.feature('coach_push', true) then return null; end if;
  if tg_op = 'INSERT' then
    if new.status = 'confirmed' then k := 'private_new'; end if;
  elsif new.status = 'cancelled' and old.status = 'confirmed' and old.coach_id = new.coach_id then k := 'private_off';
  elsif new.status = 'confirmed' and (old.status is distinct from 'confirmed' or old.coach_id is distinct from new.coach_id) then k := 'private_new';
  elsif new.status = 'confirmed' and (old.date, old.start_time) is distinct from (new.date, new.start_time) then k := 'private_move';
  end if;
  if k is null then return null; end if;
  -- not when the coach did it themselves
  if private.my_staff_id() is not distinct from new.coach_id then return null; end if;
  if not exists (select 1 from public.push_subs s where s.staff_id = new.coach_id and s.off_at is null) then return null; end if;
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
  if to_regclass('public.privates') is null or to_regclass('public.push_subs') is null then raise notice 'no privates or push_subs here, skipped'; return; end if;
  drop trigger if exists privates_coach_push on public.privates;
  create trigger privates_coach_push after insert or update of status, coach_id, date, start_time on public.privates for each row execute function private.private_coach_push();
end $p$;

notify pgrst, 'reload schema';
