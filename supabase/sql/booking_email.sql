-- Email the office when a new booking comes in:
--   stays: website bookings once paid, MotoPress, Booking.com, Airbnb and Agoda (anything not typed in by staff)
--   website orders: packages and courses bought on the website, once paid
-- Each booking is emailed once (private.booking_mails). The address is app_settings 'booking_email' (default hello@phuketking.com).

create table if not exists private.booking_mails (
  kind text not null,
  ref uuid not null,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  error text,
  primary key (kind, ref)
);

create or replace function private.booking_mail(p_kind text, p_ref uuid) returns void language plpgsql security definer set search_path='' as $f$
declare tok text;
begin
  insert into private.booking_mails(kind, ref) values (p_kind, p_ref) on conflict do nothing;
  if not found then return; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  perform net.http_post(url := 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/notify',
    body := jsonb_build_object('kind', p_kind, 'id', p_ref),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
exception when others then null;  -- never block a booking because of an email
end $f$;

-- a new stay that staff did not type in themselves
create or replace function private.stay_mail_new() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if new.status <> 'cancelled' and new.hold_until is null and auth.uid() is null then perform private.booking_mail('stay', new.id); end if;
  return null;
end $f$;
drop trigger if exists stays_mail_new on public.stays;
create trigger stays_mail_new after insert on public.stays for each row execute function private.stay_mail_new();

-- a website booking once it is paid (the hold is cleared)
create or replace function private.stay_mail_paid() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if old.hold_until is not null and new.hold_until is null and new.status <> 'cancelled' then perform private.booking_mail('stay', new.id); end if;
  return null;
end $f$;
drop trigger if exists stays_mail_paid on public.stays;
create trigger stays_mail_paid after update of hold_until on public.stays for each row execute function private.stay_mail_paid();

-- website package or course orders once paid
create or replace function private.webpkg_mail() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if new.status = 'paid' and coalesce(old.status, '') <> 'paid' then perform private.booking_mail('webpkg', new.id); end if;
  return null;
end $f$;
drop trigger if exists web_pkg_orders_mail on public.web_pkg_orders;
create trigger web_pkg_orders_mail after update of status on public.web_pkg_orders for each row execute function private.webpkg_mail();

-- the function reads everything it needs from here (service role only)
create or replace function public.booking_mail_data(p_kind text, p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare r jsonb;
begin
  if p_kind = 'stay' then
    select jsonb_build_object('kind','stay','id', s.id, 'guest', c.name, 'email', c.email, 'phone', c.phone, 'room', rm.name,
      'from', s.check_in, 'to', s.check_out, 'nights', s.check_out - s.check_in, 'guests', s.guests, 'status', s.status,
      'source', coalesce(bs.name, case when s.external_id like 'web:%' then 'Website (phuketking.com)' when s.external_id like 'mphb:%' then 'Website (MotoPress)'
                                        when s.ical_feed is not null then 'Booking site calendar' else 'Direct' end),
      'price', s.room_price_thb, 'paid', coalesce(s.room_paid_thb,0)
               + coalesce((select sum(p.amount_thb) from public.payments p where p.stay_id = s.id and not p.voided),0),
      'training', s.training_included, 'notes', s.notes, 'affiliate', af.name,
      'extras', coalesce((select jsonb_agg(jsonb_build_object('name', k.package_name, 'price', k.price_thb, 'paid', k.paid_thb) order by k.created_at)
         from public.purchases k where k.for_stay = s.id and not k.cancelled), '[]'::jsonb)
                || coalesce((select jsonb_agg(jsonb_build_object('name', rc.description, 'price', rc.amount_thb, 'paid', 0) order by rc.created_at)
         from public.room_charges rc where rc.stay_id = s.id and not coalesce(rc.voided,false)), '[]'::jsonb),
      'to_email', coalesce((select nullif(value,'') from public.app_settings where key = 'booking_email'), 'hello@phuketking.com'))
    into r
    from public.stays s left join public.customers c on c.id = s.customer_id left join public.rooms rm on rm.id = s.room_id
      left join public.booking_sources bs on bs.id = s.source_id left join public.affiliates af on af.id = s.affiliate_id
    where s.id = p_id;
  elsif p_kind = 'webpkg' then
    select jsonb_build_object('kind','webpkg','id', o.id, 'what', o.package_name, 'price', o.price_thb, 'guest', o.name, 'email', o.email, 'phone', o.phone,
      'start', o.start_on, 'note', o.note, 'paid_at', o.paid_at, 'course', o.course_id is not null,
      'method', case when o.stripe_session like 'claim:%' then 'PromptPay (desk to check)' else 'Card online' end,
      'to_email', coalesce((select nullif(value,'') from public.app_settings where key = 'booking_email'), 'hello@phuketking.com'))
    into r from public.web_pkg_orders o where o.id = p_id;
  end if;
  return r;
end $f$;
revoke all on function public.booking_mail_data(text, uuid) from public, anon, authenticated;

create or replace function public.booking_mail_done(p_kind text, p_id uuid, p_error text) returns void language sql security definer set search_path='' as $f$
  update private.booking_mails set sent_at = case when p_error is null then now() end, error = p_error where kind = p_kind and ref = p_id
$f$;
revoke all on function public.booking_mail_done(text, uuid, text) from public, anon, authenticated;
