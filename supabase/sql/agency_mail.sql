-- Booking emails read into the app (feature: agency_mail).
-- Confirmation emails from agencies (Get Your Guide, Viator, Klook and others) and booking sites (Booking.com, Airbnb) reach the
-- booking-mail function: forwarded by a small script in the business's Gmail, or pasted in the app. The AI reads each one and
-- agency_mail_ingest() files it:
--   a group class  -> an expected arrival on the day (name, how many people, time), shown on Today with Arrived and No show
--   a private      -> a private at that date and time, given to a free coach, or a request any coach can take if none is free
--   a room stay    -> the guest's name, email and phone added to the stay that came in from the booking site's calendar
-- A cancellation email cancels what its booking made. Every email is kept (Settings, Booking emails) with what was done.

create table if not exists public.agency_bookings (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('class','private','stay','other')),
  source_id uuid references public.booking_sources(id) on delete set null,
  source_name text,
  ref text,
  guest_name text,
  people int not null default 1 check (people between 1 and 100),
  date date,
  time time,
  end_date date,
  product text,
  email text,
  phone text,
  notes text,
  status text not null default 'expected' check (status in ('expected','arrived','no_show','cancelled','filed')),
  customer_id uuid references public.customers(id) on delete set null,
  private_id uuid references public.privates(id) on delete set null,
  stay_id uuid references public.stays(id) on delete set null,
  mail_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists agency_bookings_ref on public.agency_bookings (lower(source_name), ref) where ref is not null;
create index if not exists agency_bookings_date on public.agency_bookings (date);
alter table public.agency_bookings enable row level security;
revoke all on public.agency_bookings from anon, authenticated;

create table if not exists private.inbound_mails (
  id uuid primary key default gen_random_uuid(),
  received_at timestamptz not null default now(),
  via text not null default 'forward',
  sender text,
  subject text,
  body text,
  status text not null default 'new',
  result text,
  booking_id uuid,
  confirm_link text
);
revoke all on private.inbound_mails from public, anon, authenticated;

-- the key the Gmail script sends; made once, shown to managers in Settings
create or replace function private.mail_token() returns text language plpgsql security definer set search_path to '' as $$
declare t text;
begin
  select value into t from private.sync_settings where key = 'mail_token';
  if t is null then t := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''); insert into private.sync_settings(key, value) values ('mail_token', t) on conflict (key) do update set value = excluded.value; end if;
  return t;
end $$;
create or replace function public.mail_token_ok(p_token text) returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce(p_token,'') <> '' and p_token = (select value from private.sync_settings where key = 'mail_token')
$$;
revoke all on function private.mail_token() from public, anon, authenticated;
revoke all on function public.mail_token_ok(text) from public, anon, authenticated;
grant execute on function public.mail_token_ok(text) to service_role;

-- the function keeps the email first (also the Gmail forwarding check), then files what the AI read
create or replace function public.inbound_mail_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $$
declare v uuid;
begin
  insert into private.inbound_mails(via, sender, subject, body, confirm_link)
  values (left(coalesce(p->>'via','forward'),20), left(p->>'from',200), left(p->>'subject',300), left(p->>'text',60000),
          substring(coalesce(p->>'text','') from '(https://mail[-a-z]*\.google\.com/mail/[^\s<>"]+)'))
  returning id into v;
  return v;
end $$;
create or replace function public.inbound_mail_done(p_id uuid, p_status text, p_result text, p_booking uuid default null) returns void language sql security definer set search_path to '' as $$
  update private.inbound_mails set status = left(p_status,20), result = left(p_result,500), booking_id = p_booking where id = p_id
$$;
revoke all on function public.inbound_mail_save(jsonb) from public, anon, authenticated;
revoke all on function public.inbound_mail_done(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.inbound_mail_save(jsonb) to service_role;
grant execute on function public.inbound_mail_done(uuid, text, text, uuid) to service_role;

-- what the AI read -> into the app. Returns {ok, booking, what}
create or replace function public.agency_mail_ingest(p jsonb, p_mail uuid default null) returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_kind text := lower(coalesce(p->>'kind','other')); src text := nullif(btrim(coalesce(p->>'source','')),''); v_ref text := nullif(btrim(coalesce(p->>'ref','')),'');
  nm text := nullif(left(btrim(coalesce(p->>'name','')),80),''); em text := nullif(lower(left(btrim(coalesce(p->>'email','')),120)),''); ph text := nullif(left(btrim(coalesce(p->>'phone','')),40),'');
  d date; t time; d2 date; ppl int := greatest(1, least(100, coalesce(nullif(p->>'people','')::int, 1))); cancel boolean := coalesce((p->>'cancel')::boolean, false);
  sid uuid; cid uuid; b public.agency_bookings; s public.stays; co uuid; pr int; v uuid; what text; mins int := greatest(30, least(240, coalesce(nullif(p->>'minutes','')::int, 60)));
begin
  if not private.feature('agency_mail', true) then return jsonb_build_object('ok', false, 'what', 'Booking emails are switched off.'); end if;
  begin d := nullif(p->>'date','')::date; exception when others then d := null; end;
  begin t := nullif(p->>'time','')::time; exception when others then t := null; end;
  begin d2 := nullif(p->>'end_date','')::date; exception when others then d2 := null; end;
  if v_kind not in ('class','private','stay') then v_kind := 'other'; end if;
  if src is not null then
    select id, name into sid, src from public.booking_sources where regexp_replace(lower(name),'[^a-z0-9]','','g') = regexp_replace(lower(src),'[^a-z0-9]','','g')
      or regexp_replace(lower(src),'[^a-z0-9]','','g') like '%' || regexp_replace(lower(name),'[^a-z0-9]','','g') || '%' order by length(name) desc limit 1;
    src := coalesce(src, nullif(btrim(coalesce(p->>'source','')),''));
    if sid is null and v_kind in ('class','private') then insert into public.booking_sources(name) values (left(src,60)) returning id into sid; end if;
  end if;
  if v_ref is not null then select * into b from public.agency_bookings ab where lower(ab.source_name) = lower(coalesce(src,'')) and ab.ref = v_ref; end if;

  -- a cancellation: undo what the booking made
  if cancel then
    if b.id is null then return jsonb_build_object('ok', true, 'what', 'A cancellation for a booking the app does not have.'); end if;
    if b.private_id is not null then update public.privates set status = 'cancelled' where id = b.private_id and status <> 'cancelled'; end if;
    update public.agency_bookings set status = 'cancelled', updated_at = now() where id = b.id;
    return jsonb_build_object('ok', true, 'booking', b.id, 'what', 'Cancelled: ' || coalesce(b.guest_name,'guest') || coalesce(', ' || to_char(b.date,'FMDD Mon'), '') || '.');
  end if;
  if b.id is not null then return jsonb_build_object('ok', true, 'booking', b.id, 'what', 'Already in the app.'); end if;

  -- the customer: by email, else a new one
  if em is not null then select id into cid from public.customers where lower(email) = em limit 1; end if;
  if cid is null and nm is not null and v_kind <> 'stay' then
    insert into public.customers(name, email, phone, lead_source) values (nm, em, ph, coalesce(src,'Agency')) returning id into cid;
  end if;

  if v_kind = 'private' and d is not null and t is not null then
    -- a free coach at that time, else a request any coach can take
    select s2.id into co from private.bookable_coaches() s2 where to_char(t,'HH24:MI') = any (private.coach_free_times(s2.id, d, mins, null)) order by random() limit 1;
    select coalesce(price_thb, 0) into pr from public.booking_sources where id = sid;
    insert into public.privates(customer_id, coach_id, date, start_time, minutes, source_id, price_thb, coach_pct, status, paid, notes, any_coach, guest_name)
    values (cid, co, d, t, mins, sid, coalesce(pr,0), coalesce((select commission_pct from public.staff where id = co), 50),
      case when co is null then 'requested' else 'confirmed' end, false,
      left(concat_ws('. ', coalesce(src,'Agency') || coalesce(' booking ' || v_ref, ''), case when ppl > 1 then ppl || ' people' end, nullif(p->>'notes','')), 500), true,
      case when cid is null then nm end)
    returning id into v;
    insert into public.agency_bookings(kind, source_id, source_name, ref, guest_name, people, date, time, product, email, phone, notes, status, customer_id, private_id, mail_id)
    values ('private', sid, src, v_ref, nm, ppl, d, t, left(p->>'product',200), em, ph, left(p->>'notes',500), 'expected', cid, v, p_mail) returning * into b;
    if co is null then perform private.private_request_notice(v, 'through ' || coalesce(src,'an agency')); end if;
    what := 'Private ' || to_char(d,'FMDy DD Mon') || ' ' || to_char(t,'HH24:MI') || case when co is null then ', waiting for a coach' else ' with ' || (select name from public.staff where id = co) end || '.';

  elsif v_kind = 'stay' and d is not null then
    -- the stay the booking site's calendar made: same dates, still with its placeholder guest
    select st.* into s from public.stays st left join public.customers c on c.id = st.customer_id
      where st.check_in = d and (d2 is null or st.check_out = d2) and st.status <> 'cancelled'
      order by (st.ical_feed is not null and coalesce(c.name,'') ilike '%guest%') desc, (st.ical_feed ilike '%' || coalesce(lower(split_part(src,' ',1)),'') || '%') desc limit 1;
    if s.id is not null and nm is not null then
      if exists (select 1 from public.customers c where c.id = s.customer_id and c.name ilike '%guest%') or s.customer_id is null then
        if cid is null then insert into public.customers(name, email, phone, lead_source) values (nm, em, ph, coalesce(src,'Booking site')) returning id into cid; end if;
        update public.stays set customer_id = cid, guests = coalesce(guests, case when ppl > 1 then ppl || ' guests' end),
          notes = left(concat_ws('. ', notes, coalesce(src,'Booking site') || coalesce(' booking ' || v_ref, '')), 1000) where id = s.id;
        what := 'Name added to the stay ' || to_char(d,'FMDD Mon') || ': ' || nm || '.';
      else what := 'The stay ' || to_char(d,'FMDD Mon') || ' already has a guest name.'; end if;
    else what := 'No stay found for ' || coalesce(to_char(d,'FMDD Mon'),'those dates') || '. Check Stays.'; end if;
    insert into public.agency_bookings(kind, source_id, source_name, ref, guest_name, people, date, end_date, product, email, phone, notes, status, customer_id, stay_id, mail_id)
    values ('stay', sid, src, v_ref, nm, ppl, d, d2, left(p->>'product',200), em, ph, left(p->>'notes',500), 'filed', cid, s.id, p_mail) returning * into b;

  elsif v_kind = 'class' and d is not null then
    insert into public.agency_bookings(kind, source_id, source_name, ref, guest_name, people, date, time, product, email, phone, notes, status, customer_id, mail_id)
    values ('class', sid, src, v_ref, nm, ppl, d, t, left(p->>'product',200), em, ph, left(p->>'notes',500), 'expected', cid, p_mail) returning * into b;
    what := 'Group class ' || to_char(d,'FMDy DD Mon') || coalesce(' ' || to_char(t,'HH24:MI'), '') || ': ' || coalesce(nm,'guest') || case when ppl > 1 then ', ' || ppl || ' people' else '' end || '.';

  else
    insert into public.agency_bookings(kind, source_id, source_name, ref, guest_name, people, date, time, product, email, phone, notes, status, customer_id, mail_id)
    values ('other', sid, src, v_ref, nm, ppl, d, t, left(p->>'product',200), em, ph, left(p->>'notes',500), 'filed', cid, p_mail) returning * into b;
    what := 'Kept, but it is not a class, private or stay the app can file. Check it in Settings, Booking emails.';
  end if;
  return jsonb_build_object('ok', true, 'booking', b.id, 'what', what);
end $$;
revoke all on function public.agency_mail_ingest(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.agency_mail_ingest(jsonb, uuid) to service_role;

-- staff: today's (or any day's) agency arrivals, and marking them
create or replace function public.agency_bookings_day(p_day date default null) returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not private.any_staff() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'source', a.source_name, 'ref', a.ref, 'name', coalesce(c.name, a.guest_name, 'Guest'),
      'people', a.people, 'time', to_char(a.time,'HH24:MI'), 'product', a.product, 'status', a.status, 'customer_id', a.customer_id, 'private_id', a.private_id) order by a.time nulls last, a.created_at)
    from public.agency_bookings a left join public.customers c on c.id = a.customer_id
    where a.date = coalesce(p_day, private.bkk_today()) and a.kind = 'class' and a.status <> 'cancelled'), '[]'::jsonb);
end $$;
create or replace function public.agency_booking_set(p_id uuid, p_status text) returns void language plpgsql security definer set search_path to '' as $$
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  if p_status not in ('expected','arrived','no_show') then raise exception 'Choose arrived or no show.'; end if;
  update public.agency_bookings set status = p_status, updated_at = now() where id = p_id and kind = 'class';
end $$;
-- managers: the emails and what was done with them, and the Gmail script's key
create or replace function public.inbound_mails_list(p_limit int default 50) returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin') then raise exception 'Only managers see the booking emails.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'at', m.received_at, 'via', m.via, 'from', m.sender, 'subject', m.subject, 'status', m.status, 'result', m.result,
      'confirm', m.confirm_link) order by m.received_at desc) from (select * from private.inbound_mails order by received_at desc limit least(coalesce(p_limit,50),200)) m), '[]'::jsonb);
end $$;
create or replace function public.mail_token_get() returns text language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner sees this.'; end if;
  return private.mail_token();
end $$;
revoke all on function public.agency_bookings_day(date), public.agency_booking_set(uuid, text), public.inbound_mails_list(int), public.mail_token_get() from public, anon;
grant execute on function public.agency_bookings_day(date), public.agency_booking_set(uuid, text), public.inbound_mails_list(int), public.mail_token_get() to authenticated;
notify pgrst, 'reload schema';
