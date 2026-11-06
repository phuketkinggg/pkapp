-- Private health records (feature health_private): a member's health (member file, health numbers, blood tests, injuries from the About you form)
-- is seen only by the health keepers (app_settings health_keepers: staff ids; not set = the managers) and by the staff a keeper allows,
-- for one member or for every member. Only a keeper can allow or stop someone. With the feature off, the member's coaches and the managers see it, as before.
-- The patches to the functions that read health are in health_private_patch.sql.

create table if not exists public.health_access (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  granted_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists health_access_one on public.health_access (staff_id, customer_id) where customer_id is not null;
create unique index if not exists health_access_all on public.health_access (staff_id) where customer_id is null;
alter table public.health_access enable row level security;

create or replace function private.health_keeper_ids() returns uuid[]
language plpgsql stable security definer set search_path to '' as $$
declare v jsonb; ids uuid[];
begin
  begin v := (select value::jsonb from public.app_settings where key = 'health_keepers'); exception when others then v := null; end;
  if jsonb_typeof(v) = 'array' then
    select array_agg(s.id) into ids from public.staff s where s.active and s.id::text in (select jsonb_array_elements_text(v));
  end if;
  if ids is null or cardinality(ids) = 0 then select array_agg(s.id) into ids from public.staff s where s.active and s.role = 'manager'; end if;
  return coalesce(ids, '{}'::uuid[]);
end $$;

create or replace function private.health_keeper() returns boolean
language sql stable security definer set search_path to '' as $$
  select private.my_staff_id() is not null and private.my_staff_id() = any(private.health_keeper_ids())
$$;

create or replace function private.health_can(p_customer uuid) returns boolean
language plpgsql stable security definer set search_path to '' as $$
declare me uuid := private.my_staff_id();
begin
  if not private.feature('health_private', true) then return private.coach_can(p_customer); end if;
  if me is null then return false; end if;
  if me = any(private.health_keeper_ids()) then return true; end if;
  return exists (select 1 from public.health_access a join public.staff s on s.id = a.staff_id and s.active
    where a.staff_id = me and (a.customer_id = p_customer or a.customer_id is null));
end $$;

-- who can see health records: the keepers, staff allowed for every member, and (with p_customer) staff allowed for this member
create or replace function public.health_access_list(p_customer uuid default null) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare k uuid[] := private.health_keeper_ids();
begin
  if private.my_staff_id() is null then raise exception 'Staff only.'; end if;
  return jsonb_build_object(
    'on', private.feature('health_private', true),
    'keeper', private.health_keeper(),
    'can', case when p_customer is null then private.health_keeper() else private.health_can(p_customer) end,
    'keepers', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name) from public.staff s where s.id = any(k)), '[]'::jsonb),
    'set', (select value is not null from public.app_settings where key = 'health_keepers'),
    'grants', case when private.health_keeper() then coalesce((select jsonb_agg(jsonb_build_object('staff_id', a.staff_id, 'name', s.name, 'all', a.customer_id is null, 'at', a.created_at) order by s.name)
        from public.health_access a join public.staff s on s.id = a.staff_id and s.active
        where a.customer_id is null or a.customer_id = p_customer), '[]'::jsonb) else '[]'::jsonb end,
    'staff', case when private.health_keeper() then coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', s.role) order by s.name)
        from public.staff s where s.active and s.user_id is not null and not (s.id = any(k))), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- allow or stop one person: for one member (p_customer) or every member (p_customer null). Keepers only.
create or replace function public.health_access_set(p_staff uuid, p_customer uuid, p_on boolean) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if not private.health_keeper() then raise exception 'Only the owner of the health records can change who sees them.'; end if;
  if not exists (select 1 from public.staff where id = p_staff and active) then raise exception 'That person is not on the team.'; end if;
  if p_on then
    if not exists (select 1 from public.health_access where staff_id = p_staff and customer_id is not distinct from p_customer) then
      insert into public.health_access (staff_id, customer_id, granted_by) values (p_staff, p_customer, private.my_staff_id());
    end if;
  else
    delete from public.health_access where staff_id = p_staff and customer_id is not distinct from p_customer;
  end if;
end $$;

-- the keepers themselves: who owns the health records. Keepers only, and never empty.
create or replace function public.health_keepers_set(p_staff uuid[]) returns void
language plpgsql security definer set search_path to '' as $$
declare ids uuid[];
begin
  if not private.health_keeper() then raise exception 'Only the owner of the health records can change this.'; end if;
  select array_agg(id) into ids from public.staff where active and id = any(p_staff);
  if ids is null or cardinality(ids) = 0 then raise exception 'Keep at least one person.'; end if;
  insert into public.app_settings (key, value) values ('health_keepers', to_jsonb(ids)::text)
    on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- everything known about one customer, newest first: bookings, packages, website orders, payments, privates, courses, shop, emails, visits, app use.
-- Health is in it only for the people allowed to see it.
create or replace function public.customer_info(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare c public.customers%rowtype; u record; ev jsonb; hl jsonb := null; ok boolean;
begin
  if private.my_staff_id() is null then raise exception 'Staff only.'; end if;
  select * into c from public.customers where id = p_customer; if c.id is null then raise exception 'That customer is not there any more.'; end if;
  select a.created_at, a.last_sign_in_at into u from auth.users a where a.id = c.user_id;
  select coalesce(jsonb_agg(e order by (e->>'at')::timestamptz desc), '[]'::jsonb) into ev from (
    select jsonb_build_object('at', c.created_at, 'kind', 'customer', 'what', 'Added as a customer', 'detail', null) e
    union all select jsonb_build_object('at', u.created_at, 'kind', 'app', 'what', 'Made their app account', 'detail', c.email) where u.created_at is not null
    union all select jsonb_build_object('at', u.last_sign_in_at, 'kind', 'app', 'what', 'Last signed in to the app', 'detail', null) where u.last_sign_in_at is not null
    union all select jsonb_build_object('at', s.created_at, 'kind', 'stay', 'what', 'Booked a stay: ' || coalesce(r.name, 'room') || ', ' || to_char(s.check_in, 'FMDD Mon YYYY') || ' to ' || to_char(s.check_out, 'FMDD Mon YYYY'),
        'detail', concat_ws('. ', 'Through ' || coalesce(src.name, case when s.external_id like 'mphb:%' then 'the website' else 'the desk' end), case when s.room_price_thb is not null then 'Room ' || s.room_price_thb || ' THB' end,
          s.guests, case when s.guest_names is not null then 'Staying: ' || replace(s.guest_names, E'\n', ', ') end, 'Status: ' || s.status, case when s.settled then 'Settled ' || coalesce(to_char(s.settled_on, 'FMDD Mon YYYY'), '') end))
      from public.stays s left join public.rooms r on r.id = s.room_id left join public.booking_sources src on src.id = s.source_id where s.customer_id = p_customer
    union all select jsonb_build_object('at', o.created_at, 'kind', 'web', 'what', 'Ordered on the website: ' || coalesce(o.package_name, 'a package'),
        'detail', concat_ws('. ', o.price_thb || ' THB', case when o.start_on is not null then 'Starting ' || to_char(o.start_on, 'FMDD Mon YYYY') end,
          case when o.paid_at is not null then 'Paid ' || to_char(o.paid_at at time zone 'Asia/Bangkok', 'FMDD Mon HH24:MI') else 'Status: ' || o.status end, nullif(o.note, '')))
      from public.web_pkg_orders o where o.customer_id = p_customer
    union all select jsonb_build_object('at', p.created_at, 'kind', 'package', 'what', 'Package: ' || p.package_name,
        'detail', concat_ws('. ', p.price_thb || ' THB', 'Bought ' || to_char(p.purchased_on, 'FMDD Mon YYYY'),
          case when p.ordered_in_app then 'In the app' when exists (select 1 from public.web_pkg_orders w where w.purchase_id = p.id) then 'On the website' when p.stay_id is not null then 'With the stay' else 'At the desk' end,
          case when p.method is not null then 'Paid by ' || p.method end, case when p.sold_by is not null then 'By ' || (select name from public.staff where id = p.sold_by) end,
          case when p.starts_on is not null then 'Runs ' || to_char(p.starts_on, 'FMDD Mon') || coalesce(' to ' || to_char(p.expires_on, 'FMDD Mon YYYY'), '') end,
          case when p.cancelled then 'Cancelled' end, case when p.refunded_at is not null then 'Refunded ' || coalesce(p.refund_thb::text || ' THB', '') end))
      from public.purchases p where p.customer_id = p_customer
    union all select jsonb_build_object('at', y.at, 'kind', 'payment', 'what', case when y.amount_thb < 0 then 'Refund ' || (-y.amount_thb) || ' THB' else 'Paid ' || y.amount_thb || ' THB' end || ' by ' || y.method,
        'detail', coalesce((select k.package_name from public.purchases k where k.id = y.purchase_id), case when y.stay_id is not null then 'Room bill' when y.private_id is not null then 'Private session' end, y.note))
      from public.payments y where y.customer_id = p_customer and not y.voided
    union all select jsonb_build_object('at', x.created_at, 'kind', 'private', 'what', 'Private session ' || to_char(x.date, 'FMDD Mon YYYY') || coalesce(' ' || to_char(x.start_time, 'HH24:MI'), ''),
        'detail', concat_ws('. ', (select 'With ' || name from public.staff where id = x.coach_id), 'Status: ' || x.status, case when x.web then 'Booked online' end))
      from public.privates x where x.customer_id = p_customer
    union all select jsonb_build_object('at', a.created_at, 'kind', 'course', 'what', 'Got the online course ' || coalesce(k.title, ''), 'detail', a.source)
      from public.course_access a left join public.courses k on k.id = a.course_id where a.customer_id = p_customer
    union all select jsonb_build_object('at', max(g.done_at), 'kind', 'course', 'what', 'Watched ' || count(*) || ' course lesson' || case when count(*) = 1 then '' else 's' end, 'detail', null)
      from public.course_progress g where g.customer_id = p_customer and g.done having count(*) > 0
    union all select jsonb_build_object('at', so.created_at, 'kind', 'shop', 'what', 'Shop order #' || so.number || ', ' || so.total_thb || ' THB', 'detail', concat_ws('. ', 'Status: ' || so.status, case when so.web then 'Ordered in the app' end, so.method))
      from public.shop_orders so where so.customer_id = p_customer
    union all select jsonb_build_object('at', ab.created_at, 'kind', 'agency', 'what', 'Agency booking: ' || coalesce(ab.product, ab.kind), 'detail', concat_ws('. ', ab.source_name, ab.ref, to_char(ab.date, 'FMDD Mon YYYY'), ab.people || ' people'))
      from public.agency_bookings ab where ab.customer_id = p_customer
    union all select jsonb_build_object('at', coalesce(m.sent_at, m.created_at), 'kind', 'email', 'what', 'Email: ' || m.subject, 'detail', m.status)
      from public.sent_emails m where m.customer_id = p_customer
    union all select jsonb_build_object('at', min(ch.checked_in_at), 'kind', 'visit', 'what', 'First visit', 'detail', null) from public.checkins ch where ch.customer_id = p_customer having count(*) > 0
    union all select jsonb_build_object('at', max(ch.checked_in_at), 'kind', 'visit', 'what', 'Last visit (' || count(*) || ' in all)', 'detail', null) from public.checkins ch where ch.customer_id = p_customer having count(*) > 0
    union all select jsonb_build_object('at', pa.sent_at, 'kind', 'app', 'what', 'Sent the About you form', 'detail', pa.sent_to) from public.prearrival pa where pa.customer_id = p_customer and pa.sent_at is not null
    union all select jsonb_build_object('at', pa.opened_at, 'kind', 'app', 'what', 'Opened the About you form', 'detail', null) from public.prearrival pa where pa.customer_id = p_customer and pa.opened_at is not null
    union all select jsonb_build_object('at', pa.done_at, 'kind', 'app', 'what', 'Filled in the About you form', 'detail', case when pa.arrival is not null then 'Arriving ' || to_char(pa.arrival, 'FMDD Mon YYYY') end) from public.prearrival pa where pa.customer_id = p_customer and pa.done_at is not null
    union all select jsonb_build_object('at', ht.created_at, 'kind', 'chat', 'what', 'Started a chat', 'detail', ht.title) from public.chats ht where ht.customer_id = p_customer
    union all select jsonb_build_object('at', iv.created_at, 'kind', 'invoice', 'what', 'Invoice ' || iv.number || ', ' || iv.total || ' THB', 'detail', 'Status: ' || iv.status) from public.invoices iv where iv.customer_id = p_customer
    union all select jsonb_build_object('at', fa.created_at, 'kind', 'fighter', 'what', 'Applied to fight for the gym', 'detail', 'Status: ' || fa.status) from public.fighter_applications fa where fa.customer_id = p_customer
    union all select jsonb_build_object('at', n.created_at, 'kind', 'notice', 'what', n.title, 'detail', n.detail) from public.notices n where n.customer_id = p_customer and n.kind <> 'prearrival'
    ) x where e->>'at' is not null;
  ok := private.health_can(p_customer);
  if ok then
    hl := jsonb_build_object(
      'file', (select to_jsonb(f) - 'photo' from public.member_file f where f.customer_id = p_customer),
      'intake', (select jsonb_strip_nulls(jsonb_build_object('injury', coalesce(ci.answers, pa.answers)->>'injury', 'injury_where', coalesce(ci.answers, pa.answers)->>'injury_where', 'injury_note', coalesce(ci.answers, pa.answers)->>'injury_note', 'allergies', coalesce(ci.answers, pa.answers)->>'allergies'))
        from (select 1) one left join public.customer_intake ci on ci.customer_id = p_customer left join public.prearrival pa on pa.customer_id = p_customer),
      'marks', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'value', h.value, 'value2', h.value2, 'at', h.at, 'note', h.note) order by h.at desc) from (select * from public.health_marks where customer_id = p_customer and not removed order by at desc limit 40) h), '[]'::jsonb),
      'docs', coalesce((select jsonb_agg(jsonb_build_object('name', d.name, 'kind', d.kind, 'at', d.created_at) order by d.created_at desc) from public.member_docs d where d.customer_id = p_customer and not d.removed), '[]'::jsonb),
      'notes', (select count(*) from public.member_notes n where n.customer_id = p_customer and not n.removed));
    if private.my_staff_id() is not null then insert into public.member_file_views (customer_id, staff_id) values (p_customer, private.my_staff_id()); end if;
  end if;
  return jsonb_build_object('customer', to_jsonb(c), 'signed_up', u.created_at, 'last_sign_in', u.last_sign_in_at,
    'spent', (select coalesce(sum(amount_thb), 0) from public.payments where customer_id = p_customer and not voided),
    'visits', (select count(*) from public.checkins where customer_id = p_customer),
    'referred_by', (select a.name from public.affiliates a where a.id = coalesce((select affiliate_id from public.stays where customer_id = p_customer and affiliate_id is not null limit 1), (select affiliate_id from public.purchases where customer_id = p_customer and affiliate_id is not null limit 1))),
    'events', ev, 'health_ok', ok, 'health', hl);
end $$;

revoke all on function private.health_keeper_ids(), private.health_keeper(), private.health_can(uuid) from public, anon;
grant execute on function private.health_can(uuid), private.health_keeper(), private.health_keeper_ids() to authenticated;
revoke all on function public.health_access_list(uuid), public.health_access_set(uuid, uuid, boolean), public.health_keepers_set(uuid[]), public.customer_info(uuid) from public, anon;
grant execute on function public.health_access_list(uuid), public.health_access_set(uuid, uuid, boolean), public.health_keepers_set(uuid[]), public.customer_info(uuid) to authenticated;
