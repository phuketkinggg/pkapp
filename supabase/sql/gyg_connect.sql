-- GetYourGuide connection (feature gyg_connect, off unless switched on): GetYourGuide asks the app what is free and books
-- straight into it, so the booking never has to be copied from an email. The business lists what it sells there as products:
-- a group class (matched to the timetable by name, with a number of places) or a private (start times, as many places as
-- coaches free). A booking is filed like an agency booking email: the guest, the class or a private with a free coach, and the
-- booking notification. GetYourGuide connects with the address, user name and password shown in the app (Settings, Privates).
-- The edge function gyg passes each request to public.gyg_api.

create table if not exists public.gyg_products (
  id text primary key check (id ~ '^[A-Za-z0-9_-]{1,40}$'),
  title text not null,
  kind text not null default 'class' check (kind in ('class','private')),
  match text,                       -- class: words in the class name or discipline, for example Muay Thai
  times text[],                     -- private: start times, for example {08:00,10:00,14:00}
  minutes integer not null default 60 check (minutes between 15 and 480),
  capacity integer not null default 10 check (capacity between 1 and 500),
  cutoff_minutes integer not null default 60 check (cutoff_minutes between 0 and 10080),
  adult_thb integer, child_thb integer,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.gyg_products add column if not exists horizon_days integer not null default 180;
alter table public.gyg_products enable row level security;
revoke all on public.gyg_products from public, anon, authenticated;

create table if not exists public.gyg_holds (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 10)),
  product_id text not null,
  at timestamptz not null,
  people integer not null,
  items jsonb,
  gyg_ref text not null,
  expires_at timestamptz not null,
  status text not null default 'held' check (status in ('held','booked','released','cancelled')),
  booking_id uuid,
  booking_ref text unique,
  created_at timestamptz not null default now()
);
create index if not exists gyg_holds_at on public.gyg_holds (product_id, at) where status in ('held','booked');
alter table public.gyg_holds enable row level security;
revoke all on public.gyg_holds from public, anon, authenticated;

-- the free places of a product, slot by slot
create or replace function private.gyg_slots(p_product text, p_from timestamptz, p_to timestamptz)
returns table (slot_at timestamptz, vacancies integer) language plpgsql stable security definer set search_path to '' as $f$
declare k public.gyg_products; d date; t text; free int; held int; booked int; d0 date; d1 date;
begin
  select * into k from public.gyg_products where id = p_product and active;
  if k.id is null then return; end if;
  d0 := greatest((p_from at time zone 'Asia/Bangkok')::date, private.bkk_today());
  d1 := least((p_to at time zone 'Asia/Bangkok')::date, private.bkk_today() + least(coalesce(k.horizon_days, 180), 400));
  for d in select g::date from generate_series(d0, d1, interval '1 day') g loop
    if k.kind = 'class' then
      for slot_at, free in
        select distinct (d + c.start_time) at time zone 'Asia/Bangkok', k.capacity
        from public.classes c
        where c.day = extract(isodow from d)::int - 1
          and not (c.off_from is not null and d between c.off_from and coalesce(c.off_to, c.off_from))
          and (coalesce(k.match, '') = '' or c.title ilike '%' || k.match || '%' or c.discipline ilike '%' || k.match || '%')
      loop
        select coalesce(sum(b.people), 0) into booked from public.agency_bookings b
          where b.kind = 'class' and b.date = d and b.time = (slot_at at time zone 'Asia/Bangkok')::time and b.status <> 'cancelled';
        select coalesce(sum(h.people), 0) into held from public.gyg_holds h where h.product_id = k.id and h.at = slot_at and h.status = 'held' and h.expires_at > now();
        vacancies := greatest(0, free - booked - held);
        if slot_at - make_interval(mins => k.cutoff_minutes) > now() and slot_at between p_from and p_to then return next; end if;
      end loop;
    else
      foreach t in array coalesce(k.times, '{}'::text[]) loop
        if t !~ '^\d{2}:\d{2}$' then continue; end if;
        slot_at := (d + t::time) at time zone 'Asia/Bangkok';
        if not (slot_at - make_interval(mins => k.cutoff_minutes) > now() and slot_at between p_from and p_to) then continue; end if;
        select count(*) into free from private.bookable_coaches() s where t = any (private.coach_free_times(s.id, d, k.minutes, null));
        select coalesce(count(*), 0) into held from public.gyg_holds h where h.product_id = k.id and h.at = slot_at and h.status = 'held' and h.expires_at > now();
        vacancies := greatest(0, free - held);
        return next;
      end loop;
    end if;
  end loop;
end $f$;

-- the user name and password GetYourGuide signs in with (made once, kept in the database)
create or replace function private.gyg_cred() returns jsonb language plpgsql security definer set search_path to '' as $f$
declare u text; pw text;
begin
  select value into u from private.sync_settings where key = 'gyg_user';
  select value into pw from private.sync_settings where key = 'gyg_pass';
  if u is null or pw is null then
    u := 'gyg' || substr(md5(random()::text), 1, 8); pw := md5(random()::text || clock_timestamp()::text) || substr(md5(random()::text), 1, 8);
    insert into private.sync_settings(key, value) values ('gyg_user', u), ('gyg_pass', pw) on conflict (key) do update set value = excluded.value;
  end if;
  return jsonb_build_object('user', u, 'pass', pw);
end $f$;

create or replace function private.gyg_err(c text, m text) returns jsonb language sql immutable as $f$
  select jsonb_build_object('errorCode', c, 'errorMessage', m)
$f$;

-- every request from GetYourGuide: p = {op, user, pass, query or data}
create or replace function private.gyg_handle(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare op text := p->>'op'; q jsonb := coalesce(p->'query', '{}'::jsonb); d jsonb := coalesce(p->'data', '{}'::jsonb);
  cr jsonb; k public.gyg_products; h public.gyg_holds; t_at timestamptz; n int; v int; mx int; need int; r jsonb; nm text; tr jsonb; res jsonb; cats jsonb;
begin
  if not private.feature('gyg_connect', false) then return private.gyg_err('AUTHORIZATION_FAILURE', 'This connection is switched off.'); end if;
  cr := private.gyg_cred();
  if coalesce(p->>'user', '') <> cr->>'user' or coalesce(p->>'pass', '') <> cr->>'pass' then return private.gyg_err('AUTHORIZATION_FAILURE', 'Wrong user name or password.'); end if;

  if op = 'products' then
    return jsonb_build_object('data', jsonb_build_object('supplierId', coalesce(q->>'supplierId', ''), 'supplierName', private.biz_main(),
      'products', coalesce((select jsonb_agg(jsonb_build_object('productId', g.id, 'productTitle', g.title) order by g.title) from public.gyg_products g where g.active), '[]'::jsonb)));
  end if;

  if op in ('product', 'categories', 'avail', 'reserve', 'book', 'cancel_book') then
    select * into k from public.gyg_products where id = coalesce(q->>'productId', d->>'productId') and active;
    if k.id is null then return private.gyg_err('INVALID_PRODUCT', 'Unknown product.'); end if;
  end if;

  if op = 'product' then
    return jsonb_build_object('data', jsonb_build_object('supplierId', coalesce(q->>'supplierId', ''), 'productTitle', left(k.title, 512),
      'destinationLocation', jsonb_build_object('city', 'Phuket', 'country', 'THA'),
      'configuration', jsonb_build_object('participantsConfiguration', jsonb_build_object('min', 1, 'max', case when k.kind = 'private' then 10 else k.capacity end))));
  end if;

  if op = 'categories' then
    return jsonb_build_object('data', jsonb_build_object('pricingCategories',
      jsonb_build_array(jsonb_build_object('category', 'ADULT', 'minTicketAmount', 1, 'maxTicketAmount', case when k.kind = 'private' then 10 else k.capacity end, 'ageFrom', null, 'ageTo', null,
        'bookingCategory', 'STANDARD', 'price', case when k.adult_thb is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('priceType', 'RETAIL_PRICE', 'price', k.adult_thb * 100, 'currency', 'THB')) end))
      || case when k.child_thb is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('category', 'CHILD', 'minTicketAmount', 0, 'maxTicketAmount', 10, 'ageFrom', 4, 'ageTo', 15,
        'bookingCategory', 'STANDARD', 'price', jsonb_build_array(jsonb_build_object('priceType', 'RETAIL_PRICE', 'price', k.child_thb * 100, 'currency', 'THB')))) end));
  end if;

  if op = 'avail' then
    begin
      return jsonb_build_object('data', jsonb_build_object('availabilities', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('productId', k.id,
          'dateTime', to_char(s.slot_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS') || '+07:00', 'vacancies', s.vacancies, 'cutoffSeconds', k.cutoff_minutes * 60,
          'currency', case when k.adult_thb is not null then 'THB' end,
          'pricesByCategory', case when k.adult_thb is not null then jsonb_build_object('retailPrices', jsonb_build_array(jsonb_build_object('category', 'ADULT', 'price', k.adult_thb * 100))
            || case when k.child_thb is not null then jsonb_build_array(jsonb_build_object('category', 'CHILD', 'price', k.child_thb * 100)) else '[]'::jsonb end) end)) order by s.slot_at)
        from private.gyg_slots(k.id, (q->>'fromDateTime')::timestamptz, (q->>'toDateTime')::timestamptz) s), '[]'::jsonb)));
    exception when invalid_datetime_format or datetime_field_overflow then return private.gyg_err('VALIDATION_FAILURE', 'Check fromDateTime and toDateTime.'); end;
  end if;

  if op = 'reserve' then
    begin t_at := (d->>'dateTime')::timestamptz; exception when others then return private.gyg_err('VALIDATION_FAILURE', 'Check dateTime.'); end;
    if coalesce(d->>'gygBookingReference', '') = '' then return private.gyg_err('VALIDATION_FAILURE', 'gygBookingReference is missing.'); end if;
    if exists (select 1 from jsonb_array_elements(coalesce(d->'bookingItems', '[]'::jsonb)) i where i->>'category' not in ('ADULT', 'CHILD')
      or (i->>'category' = 'CHILD' and k.child_thb is null and k.adult_thb is not null)) then return private.gyg_err('INVALID_TICKET_CATEGORY', 'Only adults and children.'); end if;
    select coalesce(sum((i->>'count')::int), 0) into n from jsonb_array_elements(coalesce(d->'bookingItems', '[]'::jsonb)) i;
    if n < 1 then return private.gyg_err('VALIDATION_FAILURE', 'No travellers.'); end if;
    mx := case when k.kind = 'private' then 10 else k.capacity end;
    if n > mx then
      return jsonb_build_object('errorCode', 'INVALID_PARTICIPANTS_CONFIGURATION', 'errorMessage', 'Too many travellers.', 'participantsConfiguration', jsonb_build_object('min', 1, 'max', mx));
    end if;
    perform pg_advisory_xact_lock(hashtext('gyg:' || k.id || ':' || t_at::text));
    select s.vacancies into v from private.gyg_slots(k.id, t_at, t_at) s where s.slot_at = t_at;
    need := case when k.kind = 'private' then 1 else n end;
    if coalesce(v, 0) < need then return private.gyg_err('NO_AVAILABILITY', 'That time is full.'); end if;
    insert into public.gyg_holds (product_id, at, people, items, gyg_ref, expires_at)
      values (k.id, t_at, n, d->'bookingItems', d->>'gygBookingReference', now() + interval '60 minutes') returning * into h;
    return jsonb_build_object('data', jsonb_build_object('reservationReference', h.ref, 'reservationExpiration', to_char(h.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS') || '+00:00'));
  end if;

  if op = 'cancel_res' then
    update public.gyg_holds set status = 'released' where ref = d->>'reservationReference' and status = 'held' returning * into h;
    if h.id is null then return private.gyg_err('INVALID_RESERVATION', 'Unknown or finished reservation.'); end if;
    return jsonb_build_object('data', '{}'::jsonb);
  end if;

  if op = 'book' then
    select * into h from public.gyg_holds where ref = d->>'reservationReference' and product_id = k.id for update;
    if h.id is null or h.status in ('released', 'cancelled') then return private.gyg_err('INVALID_RESERVATION', 'Unknown or released reservation.'); end if;
    if h.status = 'booked' then
      return jsonb_build_object('data', jsonb_build_object('bookingReference', h.booking_ref, 'tickets', jsonb_build_array(jsonb_build_object('category', 'COLLECTIVE', 'ticketCode', h.booking_ref, 'ticketCodeType', 'QR_CODE'))));
    end if;
    if h.expires_at < now() then
      select s.vacancies into v from private.gyg_slots(k.id, h.at, h.at) s where s.slot_at = h.at;
      need := case when k.kind = 'private' then 1 else h.people end;
      if coalesce(v, 0) < need then return private.gyg_err('NO_AVAILABILITY', 'The hold ran out and the time is now full.'); end if;
    end if;
    tr := coalesce(d->'travelers'->0, '{}'::jsonb);
    nm := nullif(btrim(concat_ws(' ', tr->>'firstName', tr->>'lastName')), '');
    r := public.agency_mail_ingest(jsonb_build_object('kind', k.kind, 'source', 'Get Your Guide', 'ref', d->>'gygBookingReference', 'name', nm,
      'email', tr->>'email', 'phone', tr->>'phoneNumber', 'people', h.people,
      'date', to_char(h.at at time zone 'Asia/Bangkok', 'YYYY-MM-DD'), 'time', to_char(h.at at time zone 'Asia/Bangkok', 'HH24:MI'), 'minutes', k.minutes,
      'product', k.title, 'notes', left(concat_ws('. ', nullif(btrim(d->>'comment'), ''), 'Language ' || nullif(d->>'language', ''), 'Hotel ' || nullif(d->>'travelerHotel', '')), 500)));
    if not coalesce((r->>'ok')::boolean, false) then return private.gyg_err('INTERNAL_SYSTEM_FAILURE', coalesce(r->>'what', 'Could not save the booking.')); end if;
    -- a change of date or time: GetYourGuide books the new time with the same reference, then cancels the old one
    if exists (select 1 from public.agency_bookings b where b.id = (r->>'booking')::uuid
               and (b.status = 'cancelled' or b.date <> (h.at at time zone 'Asia/Bangkok')::date or b.time is distinct from (h.at at time zone 'Asia/Bangkok')::time or b.people <> h.people)) then
      update public.agency_bookings set date = (h.at at time zone 'Asia/Bangkok')::date, time = (h.at at time zone 'Asia/Bangkok')::time, people = h.people,
        status = case when status = 'cancelled' then 'expected' else status end, updated_at = now() where id = (r->>'booking')::uuid;
      update public.privates set date = (h.at at time zone 'Asia/Bangkok')::date, start_time = (h.at at time zone 'Asia/Bangkok')::time,
        status = case when status = 'cancelled' then 'confirmed' else status end
        where id = (select b.private_id from public.agency_bookings b where b.id = (r->>'booking')::uuid);
    end if;
    update public.gyg_holds set status = 'booked', booking_id = (r->>'booking')::uuid, booking_ref = 'PK' || h.ref where id = h.id returning * into h;
    return jsonb_build_object('data', jsonb_build_object('bookingReference', h.booking_ref, 'tickets', jsonb_build_array(jsonb_build_object('category', 'COLLECTIVE', 'ticketCode', h.booking_ref, 'ticketCodeType', 'QR_CODE'))));
  end if;

  if op = 'cancel_book' then
    select * into h from public.gyg_holds where booking_ref = d->>'bookingReference';
    if h.id is null then return private.gyg_err('INVALID_BOOKING', 'Unknown booking.'); end if;
    if h.status = 'cancelled' then return private.gyg_err('BOOKING_ALREADY_CANCELED', 'Already cancelled.'); end if;
    if h.at < now() then return private.gyg_err('BOOKING_IN_PAST', 'The activity has already started.'); end if;
    update public.gyg_holds set status = 'cancelled' where id = h.id;
    -- the old time of a changed booking: the booking itself stays, at its new time
    if not exists (select 1 from public.gyg_holds o where o.booking_id = h.booking_id and o.status = 'booked') then
      r := public.agency_mail_ingest(jsonb_build_object('kind', k.kind, 'source', 'Get Your Guide', 'ref', h.gyg_ref, 'cancel', true));
    end if;
    return jsonb_build_object('data', '{}'::jsonb);
  end if;

  if op = 'notify' then
    insert into public.app_settings(key, value) values ('gyg_last_notice', d::text) on conflict (key) do update set value = excluded.value;
    return jsonb_build_object('data', '{}'::jsonb);
  end if;

  return private.gyg_err('VALIDATION_FAILURE', 'Unknown request.');
exception when others then
  return private.gyg_err('INTERNAL_SYSTEM_FAILURE', left(sqlerrm, 200));
end $f$;
revoke all on function private.gyg_handle(jsonb) from public, anon, authenticated;
-- every request and the answer's error (if any) is kept for 30 days, to fix problems in the tests.
create table if not exists public.gyg_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  op text, query jsonb, data jsonb, error text, message text
);
alter table public.gyg_log enable row level security;
revoke all on public.gyg_log from public, anon, authenticated;

create or replace function public.gyg_api(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare r jsonb;
begin
  r := private.gyg_handle(p);
  insert into public.gyg_log (op, query, data, error, message)
    values (p->>'op', p->'query', (p->'data') - 'travelers', r->>'errorCode', left(coalesce(r->>'errorMessage', ''), 300));
  delete from public.gyg_log where at < now() - interval '30 days';
  return r;
end $f$;
revoke all on function public.gyg_api(jsonb) from public, anon, authenticated;

-- the manager: the connection details and the products
create or replace function public.gyg_settings() returns jsonb language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return private.gyg_cred() || jsonb_build_object('products', coalesce((select jsonb_agg(to_jsonb(g) order by g.title) from public.gyg_products g), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('product', x.product_id, 'at', x.at, 'people', x.people, 'status', x.status, 'gyg_ref', x.gyg_ref) order by x.created_at desc)
      from (select * from public.gyg_holds order by created_at desc limit 20) x), '[]'::jsonb),
    'notice', (select value from public.app_settings where key = 'gyg_last_notice'));
end $f$;

create or replace function public.gyg_product_save(p jsonb) returns text language plpgsql security definer set search_path to '' as $f$
declare pid text := nullif(btrim(coalesce(p->>'id', '')), ''); tm text[];
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  if coalesce(btrim(p->>'title'), '') = '' then raise exception 'Give it a name.'; end if;
  if pid is null then pid := left(regexp_replace(lower(btrim(p->>'title')), '[^a-z0-9]+', '-', 'g'), 30) || '-' || substr(md5(random()::text), 1, 4); end if;
  pid := trim(both '-' from pid);
  tm := array(select x from unnest(regexp_split_to_array(coalesce(p->>'times', ''), '[,; ]+')) x where x ~ '^\d{1,2}:\d{2}$' order by x);
  tm := array(select lpad(split_part(x, ':', 1), 2, '0') || ':' || split_part(x, ':', 2) from unnest(tm) x);
  if p->>'kind' = 'private' and coalesce(array_length(tm, 1), 0) = 0 then raise exception 'Add the start times, for example 08:00, 10:00, 14:00.'; end if;
  insert into public.gyg_products (id, title, kind, match, times, minutes, capacity, cutoff_minutes, adult_thb, child_thb, active, horizon_days)
  values (pid, left(btrim(p->>'title'), 200), case when p->>'kind' = 'private' then 'private' else 'class' end, nullif(btrim(coalesce(p->>'match', '')), ''), case when p->>'kind' = 'private' then tm end,
    coalesce(nullif(p->>'minutes', '')::int, 60), coalesce(nullif(p->>'capacity', '')::int, 10), coalesce(nullif(p->>'cutoff', '')::int, 60),
    nullif(p->>'adult', '')::numeric::int, nullif(p->>'child', '')::numeric::int, coalesce((p->>'active')::boolean, true), greatest(1, least(400, coalesce(nullif(p->>'horizon', '')::int, 180))))
  on conflict (id) do update set title = excluded.title, kind = excluded.kind, match = excluded.match, times = excluded.times, minutes = excluded.minutes,
    capacity = excluded.capacity, cutoff_minutes = excluded.cutoff_minutes, adult_thb = excluded.adult_thb, child_thb = excluded.child_thb, active = excluded.active, horizon_days = excluded.horizon_days;
  return pid;
end $f$;

create or replace function public.gyg_product_slots(p_id text) returns jsonb language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', to_char(s.slot_at at time zone 'Asia/Bangkok', 'Dy DD Mon HH24:MI'), 'free', s.vacancies) order by s.slot_at)
    from private.gyg_slots(p_id, now(), now() + interval '3 days') s), '[]'::jsonb);
end $f$;

revoke all on function public.gyg_settings() from public, anon;
revoke all on function public.gyg_product_save(jsonb) from public, anon;
revoke all on function public.gyg_product_slots(text) from public, anon;
grant execute on function public.gyg_settings() to authenticated;
grant execute on function public.gyg_product_save(jsonb) to authenticated;
grant execute on function public.gyg_product_slots(text) to authenticated;

notify pgrst, 'reload schema';
