-- Unpaid website room bookings (Settings, Website offer, Follow up unpaid bookings):
-- when a guest fills in the booking and starts paying but does not finish, the room is let go after 30 minutes as before.
-- Now the team gets a notice with their name, dates, total, email and phone, and about an hour later the guest gets
-- a friendly email with their stay and a link to finish the booking (and the deposit, when it is on).
-- The book function sends the emails (mode followups), every 15 minutes.

alter table public.stays add column if not exists web_followup_at timestamptz;

-- the notice for the team, as soon as the room is let go
create or replace function private.stay_unpaid_notice() returns trigger language plpgsql security definer set search_path to '' as $f$
declare c public.customers; r text; ex int;
begin
  if not (old.hold_until is not null and new.hold_until is null and new.status = 'cancelled' and coalesce(new.notes, '') like '%not paid in time%') then return null; end if;
  select * into c from public.customers where id = new.customer_id;
  select name into r from public.rooms where id = new.room_id;
  select coalesce(sum(price_thb), 0) into ex from public.purchases where for_stay = new.id;
  insert into public.notices (kind, customer_id, ref_id, title, detail)
  values ('stay', new.customer_id, new.id, 'Unpaid website booking: ' || coalesce(c.name, 'a guest') || ', ' || coalesce(r, 'a room'),
    to_char(new.check_in, 'FMDD Mon YYYY') || ' to ' || to_char(new.check_out, 'FMDD Mon YYYY') || ', ' || (new.check_out - new.check_in) || ' nights, '
      || to_char(coalesce(new.room_price_thb, 0) + ex, 'FM999,999,990') || ' THB with extras. They started paying but did not finish, so the room was let go. '
      || coalesce(c.email, 'no email') || coalesce(', ' || nullif(c.phone, ''), '') || '. '
      || case when coalesce((select value::jsonb->>'followup_on' from public.app_settings where key = 'stay_offer' and value ~ '^\s*\{'), 'true') <> 'false'
           then 'They get a friendly email in about an hour with a link to finish. A personal WhatsApp works best.' else 'Message them: a personal WhatsApp works best.' end);
  return null;
exception when others then return null;
end $f$;
drop trigger if exists stays_unpaid_notice on public.stays;
create trigger stays_unpaid_notice after update of status, hold_until on public.stays for each row execute function private.stay_unpaid_notice();

-- the follow up emails that are due (the book function asks with the sync token)
create or replace function public.web_followups_due() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', c.name, 'email', c.email, 'phone', c.phone, 'room_id', s.room_id, 'room', r.name,
      'from', s.check_in, 'to', s.check_out, 'room_price', s.room_price_thb,
      'extras', (select coalesce(jsonb_agg(jsonb_build_object('name', k.package_name, 'price', k.price_thb) order by k.created_at), '[]'::jsonb) from public.purchases k where k.for_stay = s.id))), '[]'::jsonb)
  from public.stays s join public.customers c on c.id = s.customer_id left join public.rooms r on r.id = s.room_id
  where s.status = 'cancelled' and s.web_followup_at is null and coalesce(s.notes, '') like '%not paid in time%'
    and s.created_at between now() - interval '3 days' and now() - interval '55 minutes'
    and coalesce((select value::jsonb->>'followup_on' from public.app_settings where key = 'stay_offer' and value ~ '^\s*\{'), 'true') <> 'false'
    and c.email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and c.email !~* '@example\.(com|org)$' and c.unsubscribed_at is null
    -- not when they booked again or another stay was booked for them since
    and not exists (select 1 from public.stays s2 where s2.customer_id = s.customer_id and s2.id <> s.id and s2.status in ('booked','in','out') and s2.created_at > s.created_at)
$f$;

create or replace function public.web_followup_mark(p_stay uuid) returns void language sql security definer set search_path to '' as $f$
  update public.stays set web_followup_at = now() where id = p_stay
$f$;
revoke all on function public.web_followups_due(), public.web_followup_mark(uuid), private.stay_unpaid_notice() from public, anon, authenticated;
grant execute on function public.web_followups_due(), public.web_followup_mark(uuid) to service_role;

-- every 15 minutes (only where the book function runs: the live app)
do $c$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from private.sync_settings where key = 'sync_token')
     and exists (select 1 from cron.job where jobname = 'stay-welcome-email') then
    perform cron.unschedule('stay-followup') where exists (select 1 from cron.job where jobname = 'stay-followup');
    perform cron.schedule('stay-followup', '12,27,42,57 * * * *', $j$
  select net.http_post(
    url := 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/book',
    headers := jsonb_build_object('Content-Type','application/json','x-sync-token',(select value from private.sync_settings where key='sync_token')),
    body := '{"mode":"followups"}'::jsonb,
    timeout_milliseconds := 120000);
$j$);
  else raise notice 'no cron here, the follow up emails are not scheduled';
  end if;
end $c$;

notify pgrst, 'reload schema';
