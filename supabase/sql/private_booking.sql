-- Privates booked by the hour against each coach's own hours.
--   Coaches set the hours they take privates (each weekday, from and to, with an optional break) and can close
--   days or hours in real time. Booked privates, requests waiting for an answer and website orders being paid
--   all block the time. Customers pick the coach, the day and a free time on the website (when buying a private
--   or a pack) or in the app. Every booking is a request: the coach or a manager confirms it.
--   Customers say if another coach is OK. If not, they give a backup time with the same coach.
-- Coaches with no hours set work as before (the general private hours) but are not shown on the website.

create table if not exists public.coach_hours (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  dow smallint not null check (dow between 0 and 6),  -- 0 Monday ... 6 Sunday
  from_t time not null,
  to_t time not null,
  check (to_t > from_t)
);
create index if not exists coach_hours_staff on public.coach_hours (staff_id, dow);

create table if not exists public.coach_closed (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  day date not null,
  from_t time,
  to_t time,
  note text check (char_length(note) <= 200),
  created_at timestamptz not null default now(),
  created_by uuid references public.staff(id) on delete set null,
  check ((from_t is null and to_t is null) or (from_t is not null and to_t is not null and to_t > from_t))
);
create index if not exists coach_closed_staff on public.coach_closed (staff_id, day);
alter table public.coach_hours enable row level security;
alter table public.coach_closed enable row level security;
revoke all on public.coach_hours, public.coach_closed from anon, authenticated;

alter table public.privates add column if not exists any_coach boolean not null default true;
alter table public.privates add column if not exists alt_date date;
alter table public.privates add column if not exists alt_time time;
alter table public.privates add column if not exists web_order uuid;
alter table public.privates add column if not exists coach_answer text;
alter table public.privates add column if not exists coach_answer_at timestamptz;
alter table public.web_pkg_orders add column if not exists private_req jsonb;
alter table public.staff add column if not exists bio text;
alter table public.staff add column if not exists photo_url text;

do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.notices'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' loop
    execute format('alter table public.notices drop constraint %I', c); end loop; end $$;
alter table public.notices add constraint notices_kind_check check (kind = any (array['signup','first_signin','package','stay','refund','shop','prearrival','pangea_service','private']));

-- the windows a coach takes privates on one day
create or replace function private.coach_open(p_coach uuid, p_date date)
returns table (o_from time, o_to time) language plpgsql stable security definer set search_path to '' as $$
declare hrs jsonb;
begin
  if exists (select 1 from public.coach_hours h where h.staff_id = p_coach) then
    return query select h.from_t, h.to_t from public.coach_hours h where h.staff_id = p_coach and h.dow = extract(isodow from p_date)::int - 1 order by h.from_t;
  else
    hrs := private.private_hours();
    return query select (hrs->>'from')::time, (hrs->>'to')::time;
  end if;
end $$;

-- time held for a coach: requests waiting for an answer (and their backup time), website orders being paid, closed hours
create or replace function private.coach_holds(p_coach uuid, p_date date, p_except uuid default null)
returns table (b_from time, b_to time) language sql stable security definer set search_path to '' as $$
  select x.start_time, x.start_time + make_interval(mins => x.minutes) from public.privates x
   where x.status = 'requested' and coalesce(x.coach_id, x.preferred_coach_id) = p_coach and x.date = p_date
     and x.coach_answer is distinct from 'no' and (p_except is null or x.id <> p_except)
  union all
  select x.alt_time, x.alt_time + make_interval(mins => x.minutes) from public.privates x
   where x.status = 'requested' and coalesce(x.coach_id, x.preferred_coach_id) = p_coach and x.alt_date = p_date and x.alt_time is not null
     and (p_except is null or x.id <> p_except)
  union all
  select (o.private_req->>k.t)::time, (o.private_req->>k.t)::time + interval '60 minutes'
    from public.web_pkg_orders o cross join (values ('date','time'), ('alt_date','alt_time')) k(d, t)
   where o.status = 'waiting' and o.private_req is not null and (o.private_req->>'coach')::uuid = p_coach
     and o.private_req->>k.d = to_char(p_date, 'YYYY-MM-DD') and nullif(o.private_req->>k.t, '') is not null
     and o.email is distinct from nullif(current_setting('pk.hold_email', true), '')
     and (o.created_at > now() - interval '45 minutes'
          or exists (select 1 from public.pay_claims c where c.kind = 'webpkg' and c.ref_id = o.id and c.status = 'waiting'))
  union all
  select coalesce(c.from_t, time '00:00'), coalesce(c.to_t, time '23:59:59') from public.coach_closed c
   where c.staff_id = p_coach and c.day = p_date
$$;

-- free start times for one coach on one day (inside their hours, not booked, held or closed, not in the past)
create or replace function private.coach_free_times(p_coach uuid, p_date date, p_minutes int default 60, p_except uuid default null)
returns text[] language plpgsql stable security definer set search_path to '' as $$
declare hrs jsonb := private.private_hours(); st int := greatest(15, coalesce((hrs->>'step')::int, 30)); m int := greatest(15, coalesce(p_minutes, 60));
  now_t time := (now() at time zone 'Asia/Bangkok')::time; o record; t time; out text[] := '{}';
begin
  if p_date < private.bkk_today() then return out; end if;
  for o in select * from private.coach_open(p_coach, p_date) loop
    t := o.o_from;
    while t + make_interval(mins => m) > t and t + make_interval(mins => m) <= o.o_to loop
      if not (p_date = private.bkk_today() and t <= now_t)
         and not exists (select 1 from private.coach_busy(p_coach, p_date, p_except) b where t < b.b_to and t + make_interval(mins => m) > b.b_from)
         and not exists (select 1 from private.coach_holds(p_coach, p_date, p_except) b where t < b.b_to and t + make_interval(mins => m) > b.b_from)
         and not (to_char(t, 'HH24:MI') = any (out)) then
        out := out || to_char(t, 'HH24:MI');
      end if;
      exit when t + make_interval(mins => st) <= t;
      t := t + make_interval(mins => st);
    end loop;
  end loop;
  return coalesce((select array_agg(x order by x) from unnest(out) x), '{}');
end $$;

-- the coaches customers can pick: those with hours set (all active coaches while nobody has set hours yet)
create or replace function private.bookable_coaches() returns setof public.staff language sql stable security definer set search_path to '' as $$
  select s.* from public.staff s where s.role = 'coach' and s.active
     and (exists (select 1 from public.coach_hours h where h.staff_id = s.id) or not exists (select 1 from public.coach_hours))
$$;

-- free times for the booking picker (website and app): coaches, and for each day the free start times of each coach
create or replace function public.private_book_slots(p_from date default null, p_days int default 14)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare t date := private.bkk_today(); f date := greatest(coalesce(p_from, t), t); n int := least(21, greatest(1, coalesce(p_days, 14)));
begin
  if f > t + 120 then raise exception 'Choose a date in the next four months.'; end if;
  return jsonb_build_object('today', t, 'from', f,
    'coaches', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'bio', s.bio, 'photo', s.photo_url) order by s.name) from private.bookable_coaches() s), '[]'::jsonb),
    'days', (select jsonb_agg(jsonb_build_object('date', d::date, 'free',
        coalesce((select jsonb_object_agg(s.id, to_jsonb(private.coach_free_times(s.id, d::date, 60, null))) from private.bookable_coaches() s), '{}'::jsonb)) order by d)
      from generate_series(f, f + (n - 1), interval '1 day') d));
end $$;
revoke all on function public.private_book_slots(date, int) from public;
grant execute on function public.private_book_slots(date, int) to anon, authenticated, service_role;

-- checks a booking choice {coach, date, time, any, alt_date, alt_time} and returns it tidied
create or replace function private.private_choice(p jsonb) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare c uuid; d date; tm time; ad date; atm time; anyc boolean := coalesce((p->>'any')::boolean, true); nm text; t date := private.bkk_today();
begin
  begin c := nullif(p->>'coach','')::uuid; d := nullif(p->>'date','')::date; tm := nullif(p->>'time','')::time;
        ad := nullif(p->>'alt_date','')::date; atm := nullif(p->>'alt_time','')::time;
  exception when others then raise exception 'Choose the coach, the day and the time again.'; end;
  if c is null or d is null or tm is null then raise exception 'Choose the coach, the day and the time.'; end if;
  select s.name into nm from private.bookable_coaches() s where s.id = c;
  if nm is null then raise exception 'That coach does not take privates online. Choose another coach.'; end if;
  if d < t or d > t + 120 then raise exception 'Choose a day in the next four months.'; end if;
  if not (to_char(tm, 'HH24:MI') = any (private.coach_free_times(c, d, 60, null))) then
    raise exception '% is no longer free on % at %. Choose another time.', nm, to_char(d, 'FMDy DD Mon'), to_char(tm, 'HH24:MI'); end if;
  if (ad is null) <> (atm is null) then raise exception 'Choose both the day and the time for the backup.'; end if;
  if not anyc and ad is null then raise exception 'You want % only, so choose a backup time with % too.', nm, nm; end if;
  if ad is not null then
    if ad = d and atm = tm then raise exception 'The backup time is the same as your first choice. Choose another time.'; end if;
    if ad < t or ad > t + 120 then raise exception 'Choose a backup day in the next four months.'; end if;
    if not (to_char(atm, 'HH24:MI') = any (private.coach_free_times(c, ad, 60, null))) then
      raise exception '% is not free on % at % for the backup. Choose another time.', nm, to_char(ad, 'FMDy DD Mon'), to_char(atm, 'HH24:MI'); end if;
  end if;
  return jsonb_build_object('coach', c, 'coach_name', nm, 'date', d, 'time', to_char(tm, 'HH24:MI'), 'any', anyc,
    'alt_date', ad, 'alt_time', to_char(atm, 'HH24:MI'));
end $$;

-- one line for staff: when, coach, another coach OK, backup
create or replace function private.private_choice_text(r jsonb) returns text language sql immutable set search_path to '' as $$
  select to_char((r->>'date')::date, 'FMDy DD Mon') || ' ' || (r->>'time') || ' with ' || coalesce(r->>'coach_name', 'any coach') || '.'
    || case when coalesce((r->>'any')::boolean, true) then ' Another coach is OK.' else ' They want ' || coalesce(r->>'coach_name', 'this coach') || ' only.' end
    || case when nullif(r->>'alt_date', '') is not null then ' Backup: ' || to_char((r->>'alt_date')::date, 'FMDy DD Mon') || ' ' || (r->>'alt_time') || '.' else '' end
$$;

-- a private request waiting for the coach or a manager: shown at the top of the app
create or replace function private.private_request_notice(p_id uuid, p_where text) returns void language plpgsql security definer set search_path to '' as $$
declare x public.privates; nm text; co text;
begin
  select * into x from public.privates where id = p_id;
  if not found then return; end if;
  select name into nm from public.customers where id = x.customer_id;
  select name into co from public.staff where id = coalesce(x.coach_id, x.preferred_coach_id);
  insert into public.notices (kind, customer_id, ref_id, title, detail)
  values ('private', x.customer_id, x.id, 'Private request: ' || coalesce(nm, 'Customer') || ', ' || to_char(x.date, 'FMDy DD Mon') || ' ' || to_char(x.start_time, 'HH24:MI'),
    'Booked ' || p_where || '. ' || private.private_choice_text(jsonb_build_object('date', x.date, 'time', to_char(x.start_time, 'HH24:MI'), 'coach_name', co, 'any', x.any_coach,
      'alt_date', x.alt_date, 'alt_time', to_char(x.alt_time, 'HH24:MI'))) || ' The coach or a manager confirms it. We told them within 30 minutes.');
exception when others then null;
end $$;

-- in the app: the customer picks the coach and a free time; another coach OK or a backup time
drop function if exists public.customer_request_private(uuid, date, time, text);
create or replace function public.customer_request_private(p_coach uuid, p_date date, p_time time, p_note text default null,
  p_any boolean default true, p_alt_date date default null, p_alt_time time default null)
returns uuid language plpgsql security definer set search_path to '' as $function$
declare c public.customers%rowtype; v_today date := private.bkk_today(); v_pack public.purchases%rowtype; v_source uuid; v_price integer; v_id uuid; ch jsonb;
begin
  select * into c from public.customers where id = private.customer_id();
  if not found then raise exception 'Finish setting up your account first.'; end if;
  if p_date is null or p_time is null then raise exception 'Choose a date and a time.'; end if;
  if p_date < v_today then raise exception 'That date has already passed.'; end if;
  if p_date > v_today + 120 then raise exception 'Choose a date in the next four months.'; end if;
  if p_coach is not null then
    ch := private.private_choice(jsonb_build_object('coach', p_coach, 'date', p_date, 'time', to_char(p_time, 'HH24:MI'), 'any', coalesce(p_any, true),
      'alt_date', p_alt_date, 'alt_time', to_char(p_alt_time, 'HH24:MI')));
  else
    if not exists (select 1 from private.bookable_coaches() s where to_char(p_time, 'HH24:MI') = any (private.coach_free_times(s.id, p_date, 60, null))) then
      raise exception 'No coach is free at % on %. Try another time.', to_char(p_time,'HH24:MI'), to_char(p_date,'DD Mon'); end if;
  end if;
  if (select count(*) from public.privates p where p.customer_id = c.id and p.status = 'requested') >= 5 then
    raise exception 'You already have five requests waiting. Wait for the front desk to answer those first.'; end if;
  select p.* into v_pack from public.purchases p
    where p.customer_id = c.id and 'Privates' = any (p.covers) and p.visit_limit is not null and not p.cancelled
      and (p.paid or not p.ordered_in_app) and (p.expires_on is null or p.expires_on >= p_date)
      and (select count(*) from public.privates x where x.purchase_id = p.id and x.status <> 'cancelled') + coalesce(p.used_before,0) < p.visit_limit
    order by p.expires_on nulls last, p.created_at limit 1;
  if found then v_price := round((v_pack.price_thb - v_pack.fee_thb - v_pack.tax_thb)::numeric / v_pack.visit_limit);
  else
    select b.id, private.addon_for(b.price_thb, b.price_local_thb, c.price_group) into v_source, v_price
      from public.booking_sources b where lower(b.name) = 'direct' order by b.name limit 1;
    if v_price is null then raise exception 'Privates cannot be requested in the app yet. Ask at the front desk.'; end if;
  end if;
  insert into public.privates (customer_id, coach_id, preferred_coach_id, date, start_time, source_id, purchase_id, price_thb, coach_pct, status, paid, notes, any_coach, alt_date, alt_time)
  values (c.id, null, p_coach, p_date, p_time, v_source, v_pack.id, v_price,
    coalesce((select s.commission_pct from public.staff s where s.id = p_coach), 50), 'requested', v_pack.id is not null,
    nullif(left(btrim(coalesce(p_note, '')), 500), ''),
    case when p_coach is null then true else coalesce(p_any, true) end,
    case when p_coach is not null then (ch->>'alt_date')::date end, case when p_coach is not null then nullif(ch->>'alt_time','')::time end)
  returning id into v_id;
  perform private.private_request_notice(v_id, 'in the app');
  return v_id;
end $function$;
revoke all on function public.customer_request_private(uuid, date, time, text, boolean, date, time) from public, anon;
grant execute on function public.customer_request_private(uuid, date, time, text, boolean, date, time) to authenticated;

-- ---------- coach hours: the coach for themselves, or the desk for any coach ----------
create or replace function private.hours_who(p_staff uuid) returns uuid language plpgsql stable security definer set search_path to '' as $$
declare mine uuid := private.coach_id();
begin
  if p_staff is null or p_staff = mine then
    if mine is null then raise exception 'This login is not an active coach.'; end if;
    return mine;
  end if;
  if not private.is_desk() then raise exception 'You can only change your own hours.'; end if;
  if not exists (select 1 from public.staff s where s.id = p_staff and s.role = 'coach' and s.active) then raise exception 'Choose a coach.'; end if;
  return p_staff;
end $$;

create or replace function private.coach_hours_json(p_coach uuid) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('staff_id', p_coach, 'name', (select name from public.staff where id = p_coach),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('dow', h.dow, 'from', to_char(h.from_t,'HH24:MI'), 'to', to_char(h.to_t,'HH24:MI')) order by h.dow, h.from_t)
       from public.coach_hours h where h.staff_id = p_coach), '[]'::jsonb),
    'closed', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'day', c.day, 'from', to_char(c.from_t,'HH24:MI'), 'to', to_char(c.to_t,'HH24:MI'), 'note', c.note) order by c.day, c.from_t nulls first)
       from public.coach_closed c where c.staff_id = p_coach and c.day >= private.bkk_today()), '[]'::jsonb))
$$;

create or replace function public.coach_hours_get(p_staff uuid default null) returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin return private.coach_hours_json(private.hours_who(p_staff)); end $$;

-- replaces the weekly hours: [{dow, from, to}, ...]; an empty list stops online booking for that coach
create or replace function public.coach_hours_save(p_staff uuid, p_hours jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
declare who uuid := private.hours_who(p_staff); x jsonb; f time; t time; d int;
begin
  if jsonb_typeof(coalesce(p_hours,'[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_hours,'[]'::jsonb)) > 28 then raise exception 'Hours could not be read.'; end if;
  delete from public.coach_hours where staff_id = who;
  for x in select * from jsonb_array_elements(coalesce(p_hours,'[]'::jsonb)) loop
    begin d := (x->>'dow')::int; f := (x->>'from')::time; t := (x->>'to')::time;
    exception when others then raise exception 'Type the times as hours and minutes, like 09:30.'; end;
    if d is null or d < 0 or d > 6 then raise exception 'Hours could not be read.'; end if;
    if f is null or t is null then continue; end if;
    if t <= f then raise exception 'On % the finish time is before the start time.', (array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[d+1]; end if;
    if exists (select 1 from public.coach_hours h where h.staff_id = who and h.dow = d and f < h.to_t and t > h.from_t) then
      raise exception 'On % the times overlap.', (array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[d+1]; end if;
    insert into public.coach_hours (staff_id, dow, from_t, to_t) values (who, d, f, t);
  end loop;
  return private.coach_hours_json(who);
end $$;

-- close a day or some hours (one day or a run of days). Booked privates in that time stay booked and are listed back.
create or replace function public.coach_close(p_staff uuid, p_from date, p_to date default null, p_from_t time default null, p_to_t time default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare who uuid := private.hours_who(p_staff); d date; e date := coalesce(p_to, p_from); n int := 0; kept jsonb;
begin
  if p_from is null then raise exception 'Choose the day.'; end if;
  if p_from < private.bkk_today() then raise exception 'That day has already passed.'; end if;
  if e < p_from then raise exception 'The last day is before the first day.'; end if;
  if e - p_from > 92 then raise exception 'Close up to three months at a time. For longer, ask for a holiday.'; end if;
  if (p_from_t is null) <> (p_to_t is null) then raise exception 'Choose both times, or close the whole day.'; end if;
  if p_to_t is not null and p_to_t <= p_from_t then raise exception 'The finish time is before the start time.'; end if;
  d := p_from;
  while d <= e loop
    insert into public.coach_closed (staff_id, day, from_t, to_t, note, created_by)
      values (who, d, p_from_t, p_to_t, nullif(left(btrim(coalesce(p_note,'')),200),''), private.my_staff_id());
    n := n + 1; d := d + 1;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('date', x.date, 'time', to_char(x.start_time,'HH24:MI'), 'customer', c.name) order by x.date, x.start_time), '[]'::jsonb) into kept
    from public.privates x join public.customers c on c.id = x.customer_id
   where x.coach_id = who and x.status = 'confirmed' and x.date between p_from and e
     and (p_from_t is null or (x.start_time < p_to_t and x.start_time + make_interval(mins => x.minutes) > p_from_t));
  return jsonb_build_object('closed', n, 'kept', kept, 'hours', private.coach_hours_json(who));
end $$;

create or replace function public.coach_reopen(p_id uuid) returns jsonb language plpgsql security definer set search_path to '' as $$
declare who uuid;
begin
  select staff_id into who from public.coach_closed where id = p_id;
  if who is null then raise exception 'That closed time was not found.'; end if;
  who := private.hours_who(who);
  delete from public.coach_closed where id = p_id;
  return private.coach_hours_json(who);
end $$;

-- the coach answers a request made for them: yes confirms it (if the time is still free), no hands it back to a manager
create or replace function public.coach_private_answer(p_private uuid, p_yes boolean, p_note text default null) returns void language plpgsql security definer set search_path to '' as $$
declare me uuid := private.coach_id(); x public.privates; msg text; nm text; co text;
begin
  if me is null then raise exception 'This login is not an active coach.'; end if;
  select * into x from public.privates where id = p_private for update;
  if not found or x.status <> 'requested' or coalesce(x.coach_id, x.preferred_coach_id) is distinct from me then raise exception 'That request is no longer waiting for you.'; end if;
  select name into nm from public.customers where id = x.customer_id;
  select name into co from public.staff where id = me;
  if p_yes then
    msg := private.private_clash(me, x.date, x.start_time, x.minutes, x.id);
    if msg is not null then raise exception '%', msg; end if;
    update public.privates set coach_id = me, status = 'confirmed', coach_answer = 'yes', coach_answer_at = now() where id = x.id;
    update public.notices set done_at = now(), done_by = me where kind = 'private' and ref_id = x.id and done_at is null;
  else
    update public.privates set coach_answer = 'no', coach_answer_at = now(), coach_id = null,
      notes = concat_ws(E'\n', notes, nullif('Coach note: ' || left(btrim(coalesce(p_note,'')),200), 'Coach note: ')) where id = x.id;
    update public.notices set done_at = now() where kind = 'private' and ref_id = x.id and done_at is null;
    insert into public.notices (kind, customer_id, ref_id, title, detail)
    values ('private', x.customer_id, x.id, co || ' cannot take the private: ' || coalesce(nm,'Customer') || ', ' || to_char(x.date, 'FMDy DD Mon') || ' ' || to_char(x.start_time,'HH24:MI'),
      case when x.any_coach then 'Another coach is OK for them. Approve it with another coach.'
           else 'They want ' || co || ' only.' || case when x.alt_date is not null then ' Their backup time is ' || to_char(x.alt_date, 'FMDy DD Mon') || ' ' || to_char(x.alt_time,'HH24:MI') || '.' else ' Offer them other times.' end end
      || coalesce(' Coach note: ' || nullif(btrim(p_note),''), ''));
  end if;
end $$;
revoke all on function public.coach_hours_get(uuid), public.coach_hours_save(uuid, jsonb), public.coach_close(uuid, date, date, time, time, text),
  public.coach_reopen(uuid), public.coach_private_answer(uuid, boolean, text) from public, anon;
grant execute on function public.coach_hours_get(uuid), public.coach_hours_save(uuid, jsonb), public.coach_close(uuid, date, date, time, time, text),
  public.coach_reopen(uuid), public.coach_private_answer(uuid, boolean, text) to authenticated;

-- the coach app: their requests, hours and closed times too
create or replace function public.coach_home() returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_coach uuid := private.coach_id();
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if v_coach is null then
    raise exception 'This login is not an active coach.';
  end if;
  return jsonb_build_object(
    'today', v_today,
    'privates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'date', p.date, 'time', to_char(p.start_time, 'HH24:MI'), 'until', to_char(p.start_time + make_interval(mins => p.minutes), 'HH24:MI'), 'minutes', p.minutes, 'status', p.status, 'arrived_at', p.arrived_at,
        'customer', case when c.is_agency then coalesce(nullif(p.guest_name, ''), 'Guest') || ' (' || c.name || ')'
                         when nullif(p.guest_name, '') is not null then p.guest_name || ' (' || c.name || ')'
                         else c.name end,
        'notes', p.notes,
        'share_thb', round((p.price_thb - p.fee_thb - p.tax_thb) * p.coach_pct / 100.0),
        'reschedule', p.reschedule) order by p.date, p.start_time)
      from public.privates p join public.customers c on c.id = p.customer_id
      where p.coach_id = v_coach and p.status in ('confirmed','done') and p.date >= v_today - 62), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'date', p.date, 'time', to_char(p.start_time, 'HH24:MI'),
        'until', to_char(p.start_time + make_interval(mins => p.minutes), 'HH24:MI'), 'customer', c.name, 'notes', p.notes,
        'any_coach', p.any_coach, 'alt_date', p.alt_date, 'alt_time', to_char(p.alt_time, 'HH24:MI'),
        'level', (select coalesce(ci.answers->>'self_level', ci.answers->>'level') from public.customer_intake ci where ci.customer_id = c.id)) order by p.date, p.start_time)
      from public.privates p join public.customers c on c.id = p.customer_id
      where p.status = 'requested' and coalesce(p.coach_id, p.preferred_coach_id) = v_coach and p.coach_answer is distinct from 'no' and p.date >= v_today), '[]'::jsonb),
    'avail', private.coach_hours_json(v_coach),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('day', k.day, 'time', to_char(k.start_time, 'HH24:MI'), 'title', k.title, 'off_from', k.off_from, 'off_to', k.off_to) order by k.day, k.start_time)
      from public.classes k where v_coach = any(k.coach_ids)), '[]'::jsonb),
    'holidays', coalesce((
      select jsonb_agg(jsonb_build_object('from', h.from_date, 'to', h.to_date, 'status', h.status, 'note', h.note) order by h.from_date)
      from public.holidays h where h.staff_id = v_coach and h.to_date >= v_today), '[]'::jsonb)
  );
end $function$;

-- ---------- website: buy a private or a pack and book the first session in the same go ----------
create or replace function public.web_pkg_order(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $function$
declare k public.packages; c public.courses; nm text := btrim(coalesce(p->>'name','')); em text := lower(btrim(coalesce(p->>'email','')));
  ph text := left(btrim(coalesce(p->>'phone','')),30); st date; t date := private.bkk_today(); oid uuid; n int; pr jsonb;
begin
  if char_length(nm) < 2 then raise exception 'Type your full name.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Type your email, so we can find your order.'; end if;
  select count(*) into n from public.web_pkg_orders where created_at > now() - interval '1 hour';
  if n > 100 then raise exception 'Too many orders right now. Please WhatsApp us.'; end if;
  if nullif(p->>'course_id','') is not null then
    begin select * into c from public.courses where id = (p->>'course_id')::uuid; exception when others then raise exception 'Choose a course.'; end;
    if c.id is null or c.status <> 'published' or coalesce(c.price_thb,0) < 20 then raise exception 'That course cannot be bought online.'; end if;
    insert into public.web_pkg_orders (course_id, package_name, price_thb, name, email, phone, note)
      values (c.id, 'Course: ' || c.title, c.price_thb, nm, em, nullif(ph,''), nullif(left(btrim(coalesce(p->>'note','')),300),'')) returning id into oid;
    return jsonb_build_object('id', oid, 'amount', c.price_thb, 'what', 'Course: ' || c.title, 'email', em);
  end if;
  begin select * into k from public.packages where id = (p->>'package_id')::uuid; exception when others then raise exception 'Choose a package.'; end;
  if k.id is null or not k.active or k.price_thb is null or coalesce(k.audience,'all') <> 'all' then raise exception 'That package cannot be bought online. WhatsApp us and we will help.'; end if;
  if k.price_thb < 20 then raise exception 'That package cannot be bought online.'; end if;
  -- the first private, booked now (a request until the coach or a manager confirms it)
  if jsonb_typeof(p->'private') = 'object' then
    if not ('Privates' = any (coalesce(k.covers,'{}'))) then raise exception 'Only privates can be booked here.'; end if;
    perform set_config('pk.hold_email', em, true);  -- this buyer's own earlier unpaid try does not block the time
    pr := private.private_choice(p->'private');
    if k.clock = 'purchase' and nullif(p->>'start_on','') is null then p := p || jsonb_build_object('start_on', least((pr->>'date')::date, coalesce(nullif(pr->>'alt_date','')::date, (pr->>'date')::date))); end if;
  end if;
  if k.clock = 'purchase' then
    begin st := nullif(p->>'start_on','')::date; exception when others then raise exception 'Choose the date you want to start.'; end;
    if st is null then raise exception 'Choose the date you want to start.'; end if;
    if st < t or st > t + 180 then raise exception 'Choose a start date within the next 6 months.'; end if;
    if pr is not null and st > least((pr->>'date')::date, coalesce(nullif(pr->>'alt_date','')::date, (pr->>'date')::date)) then st := least((pr->>'date')::date, coalesce(nullif(pr->>'alt_date','')::date, (pr->>'date')::date)); end if;
  end if;
  insert into public.web_pkg_orders (package_id, package_name, price_thb, name, email, phone, start_on, note, private_req)
    values (k.id, k.name, k.price_thb, nm, em, nullif(ph,''), st, nullif(left(btrim(coalesce(p->>'note','')),300),''), pr) returning id into oid;
  return jsonb_build_object('id', oid, 'amount', k.price_thb, 'what', k.name, 'email', em, 'private', pr);
end $function$;

-- once paid: the private request is made against the new pack (never stops the payment from being recorded)
create or replace function private.web_pkg_private(p_order uuid) returns void language plpgsql security definer set search_path to '' as $$
declare o public.web_pkg_orders; r jsonb; v_id uuid;
begin
  select * into o from public.web_pkg_orders where id = p_order;
  r := o.private_req;
  if r is null or o.purchase_id is null or exists (select 1 from public.privates where web_order = o.id) then return; end if;
  begin
    insert into public.privates (customer_id, coach_id, preferred_coach_id, date, start_time, purchase_id, price_thb, coach_pct, status, paid, notes, any_coach, alt_date, alt_time, web_order)
    values (o.customer_id, null, (r->>'coach')::uuid, (r->>'date')::date, (r->>'time')::time, o.purchase_id, 0,
      coalesce((select s.commission_pct from public.staff s where s.id = (r->>'coach')::uuid), 50), 'requested', true,
      nullif(left('Booked on the website.' || coalesce(' ' || o.note, ''), 500), ''), coalesce((r->>'any')::boolean, true),
      nullif(r->>'alt_date','')::date, nullif(r->>'alt_time','')::time, o.id)
    returning id into v_id;
    perform private.private_request_notice(v_id, 'on the website with their ' || o.package_name);
  exception when others then
    insert into public.notices (kind, customer_id, ref_id, title, detail)
    values ('private', o.customer_id, o.id, 'Book a private by hand: ' || o.name,
      'They bought ' || o.package_name || ' on the website and asked for ' || private.private_choice_text(r) || ' It could not be added by itself: ' || sqlerrm);
  end;
end $$;

create or replace function private.web_pkg_private_trg() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.status = 'paid' and coalesce(old.status,'') <> 'paid' and new.private_req is not null then perform private.web_pkg_private(new.id); end if;
  return null;
end $$;
drop trigger if exists web_pkg_orders_private on public.web_pkg_orders;
create trigger web_pkg_orders_private after update of status on public.web_pkg_orders for each row execute function private.web_pkg_private_trg();

-- the thank you page also says what was booked
create or replace function public.web_pkg_status(p_id uuid) returns jsonb language sql stable security definer set search_path to '' as $function$
  select case when o.id is null then null else jsonb_build_object('paid', o.status = 'paid', 'package', o.package_name, 'start_on', o.start_on,
    'course', (select c.slug from public.courses c where c.id = o.course_id),
    'first_class', (select k.clock = 'first' from public.packages k where k.id = o.package_id),
    'private', case when o.private_req is not null then o.private_req - 'coach' end,
    'checking', exists (select 1 from public.pay_claims c where c.kind = 'webpkg' and c.ref_id = o.id and c.status = 'waiting'),
    'rejected', exists (select 1 from public.pay_claims c where c.kind = 'webpkg' and c.ref_id = o.id and c.status = 'rejected')
      and not exists (select 1 from public.pay_claims c where c.kind = 'webpkg' and c.ref_id = o.id and c.status = 'waiting')) end
  from public.web_pkg_orders o where o.id = p_id
$function$;

-- ---------- emails to the customer when a request is confirmed or declined ----------
create or replace function private.private_mail_trg() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if to_regprocedure('private.booking_mail(text,uuid)') is null then return null; end if;  -- the demo has no emails
  if old.status = 'requested' and new.status = 'confirmed' then perform private.booking_mail('private_ok', new.id);
  elsif old.status = 'requested' and new.status = 'cancelled' and new.decline_reason is not null then perform private.booking_mail('private_no', new.id);
  end if;
  return null;
end $$;
drop trigger if exists privates_mail on public.privates;
create trigger privates_mail after update of status on public.privates for each row execute function private.private_mail_trg();

do $$ declare d text; begin
  if to_regprocedure('public.booking_mail_data(text,uuid)') is null then return; end if;
  d := pg_get_functiondef('public.booking_mail_data(text,uuid)'::regprocedure);
  if position('private_ok' in d) = 0 then
    d := replace(d, $a$  elsif p_kind = 'webpkg' then$a$, $b$  elsif p_kind in ('private_ok','private_no') then
    select jsonb_build_object('kind', p_kind, 'id', x.id, 'guest', c.name, 'email', c.email, 'date', x.date, 'time', to_char(x.start_time,'HH24:MI'),
      'until', to_char(x.start_time + make_interval(mins => x.minutes), 'HH24:MI'), 'coach', s.name, 'reason', x.decline_reason,
      'offers', (select jsonb_agg(jsonb_build_object('date', (o->>'date')::date, 'time', o->>'time', 'coach', (select name from public.staff where id = (o->>'coach_id')::uuid)))
                   from jsonb_array_elements(coalesce(x.offers,'[]'::jsonb)) o),
      'to_email', c.email)
    into r from public.privates x join public.customers c on c.id = x.customer_id left join public.staff s on s.id = x.coach_id
    where x.id = p_id and nullif(c.email,'') is not null;
  elsif p_kind = 'webpkg' then$b$);
    d := replace(d, $a$'start', o.start_on, 'note', o.note,$a$, $b$'start', o.start_on, 'note', o.note, 'private', case when o.private_req is not null then private.private_choice_text(o.private_req) end,$b$);
    if position('private_ok' in d) = 0 or position('private_choice_text' in d) = 0 then raise exception 'booking_mail_data patch did not apply'; end if;
    execute d;
  end if;
end $$;
