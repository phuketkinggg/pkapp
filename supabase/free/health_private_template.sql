delete from mf.template where name like 'health_private:%';
insert into mf.template (ord, phase, kind, name, sql) values (300671, 3, 'patch', 'health_private:300671', $TPL$create table if not exists __P__.health_access (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references __P__.staff(id) on delete cascade,
  customer_id uuid references __P__.customers(id) on delete cascade,
  granted_by uuid references __P__.staff(id) on delete set null,
  created_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000371, 10, 'patch', 'health_private:1000371', $TPL$create unique index if not exists health_access_one on __P__.health_access (staff_id, customer_id) where customer_id is not null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000372, 10, 'patch', 'health_private:1000372', $TPL$create unique index if not exists health_access_all on __P__.health_access (staff_id) where customer_id is null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300672, 3, 'patch', 'health_private:300672', $TPL$alter table __P__.health_access enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400971, 4, 'patch', 'health_private:400971', $TPL$create or replace function __Q__.health_keeper_ids() returns uuid[]
language plpgsql stable security definer set search_path to '' as $$
declare v jsonb; ids uuid[];
begin
  begin v := (select value::jsonb from __P__.app_settings where key = 'health_keepers'); exception when others then v := null; end;
  if jsonb_typeof(v) = 'array' then
    select array_agg(s.id) into ids from __P__.staff s where s.active and s.id::text in (select jsonb_array_elements_text(v));
  end if;
  if ids is null or cardinality(ids) = 0 then select array_agg(s.id) into ids from __P__.staff s where s.active and s.role = 'manager'; end if;
  return coalesce(ids, '{}'::uuid[]);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400972, 4, 'patch', 'health_private:400972', $TPL$create or replace function __Q__.health_keeper() returns boolean
language sql stable security definer set search_path to '' as $$
  select __Q__.my_staff_id() is not null and __Q__.my_staff_id() = any(__Q__.health_keeper_ids())
$$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400973, 4, 'patch', 'health_private:400973', $TPL$create or replace function __Q__.health_can(p_customer uuid) returns boolean
language plpgsql stable security definer set search_path to '' as $$
declare me uuid := __Q__.my_staff_id();
begin
  if not __Q__.feature('health_private', true) then return __Q__.coach_can(p_customer); end if;
  if me is null then return false; end if;
  if me = any(__Q__.health_keeper_ids()) then return true; end if;
  return exists (select 1 from __P__.health_access a join __P__.staff s on s.id = a.staff_id and s.active
    where a.staff_id = me and (a.customer_id = p_customer or a.customer_id is null));
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400974, 4, 'patch', 'health_private:400974', $TPL$create or replace function __P__.health_access_list(p_customer uuid default null) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare k uuid[] := __Q__.health_keeper_ids();
begin
  if __Q__.my_staff_id() is null then raise exception 'Staff only.'; end if;
  return jsonb_build_object(
    'on', __Q__.feature('health_private', true),
    'keeper', __Q__.health_keeper(),
    'can', case when p_customer is null then __Q__.health_keeper() else __Q__.health_can(p_customer) end,
    'keepers', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name) from __P__.staff s where s.id = any(k)), '[]'::jsonb),
    'set', (select value is not null from __P__.app_settings where key = 'health_keepers'),
    'grants', case when __Q__.health_keeper() then coalesce((select jsonb_agg(jsonb_build_object('staff_id', a.staff_id, 'name', s.name, 'all', a.customer_id is null, 'at', a.created_at) order by s.name)
        from __P__.health_access a join __P__.staff s on s.id = a.staff_id and s.active
        where a.customer_id is null or a.customer_id = p_customer), '[]'::jsonb) else '[]'::jsonb end,
    'staff', case when __Q__.health_keeper() then coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', s.role) order by s.name)
        from __P__.staff s where s.active and s.user_id is not null and not (s.id = any(k))), '[]'::jsonb) else '[]'::jsonb end);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400975, 4, 'patch', 'health_private:400975', $TPL$create or replace function __P__.health_access_set(p_staff uuid, p_customer uuid, p_on boolean) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if not __Q__.health_keeper() then raise exception 'Only the owner of the health records can change who sees them.'; end if;
  if not exists (select 1 from __P__.staff where id = p_staff and active) then raise exception 'That person is not on the team.'; end if;
  if p_on then
    if not exists (select 1 from __P__.health_access where staff_id = p_staff and customer_id is not distinct from p_customer) then
      insert into __P__.health_access (staff_id, customer_id, granted_by) values (p_staff, p_customer, __Q__.my_staff_id());
    end if;
  else
    delete from __P__.health_access where staff_id = p_staff and customer_id is not distinct from p_customer;
  end if;
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400976, 4, 'patch', 'health_private:400976', $TPL$create or replace function __P__.health_keepers_set(p_staff uuid[]) returns void
language plpgsql security definer set search_path to '' as $$
declare ids uuid[];
begin
  if not __Q__.health_keeper() then raise exception 'Only the owner of the health records can change this.'; end if;
  select array_agg(id) into ids from __P__.staff where active and id = any(p_staff);
  if ids is null or cardinality(ids) = 0 then raise exception 'Keep at least one person.'; end if;
  insert into __P__.app_settings (key, value) values ('health_keepers', to_jsonb(ids)::text)
    on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400977, 4, 'patch', 'health_private:400977', $TPL$create or replace function __P__.customer_info(p_customer uuid) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare c __P__.customers%rowtype; u record; ev jsonb; hl jsonb := null; ok boolean;
begin
  if __Q__.my_staff_id() is null then raise exception 'Staff only.'; end if;
  select * into c from __P__.customers where id = p_customer; if c.id is null then raise exception 'That customer is not there any more.'; end if;
  select a.created_at, a.last_sign_in_at into u from auth.users a where a.id = c.user_id;
  select coalesce(jsonb_agg(e order by (e->>'at')::timestamptz desc), '[]'::jsonb) into ev from (
    select jsonb_build_object('at', c.created_at, 'kind', 'customer', 'what', 'Added as a customer', 'detail', null) e
    union all select jsonb_build_object('at', u.created_at, 'kind', 'app', 'what', 'Made their app account', 'detail', c.email) where u.created_at is not null
    union all select jsonb_build_object('at', u.last_sign_in_at, 'kind', 'app', 'what', 'Last signed in to the app', 'detail', null) where u.last_sign_in_at is not null
    union all select jsonb_build_object('at', s.created_at, 'kind', 'stay', 'what', 'Booked a stay: ' || coalesce(r.name, 'room') || ', ' || to_char(s.check_in, 'FMDD Mon YYYY') || ' to ' || to_char(s.check_out, 'FMDD Mon YYYY'),
        'detail', concat_ws('. ', 'Through ' || coalesce(src.name, case when s.external_id like 'mphb:%' then 'the website' else 'the desk' end), case when s.room_price_thb is not null then 'Room ' || s.room_price_thb || ' THB' end,
          s.guests, case when s.guest_names is not null then 'Staying: ' || replace(s.guest_names, E'\n', ', ') end, 'Status: ' || s.status, case when s.settled then 'Settled ' || coalesce(to_char(s.settled_on, 'FMDD Mon YYYY'), '') end))
      from __P__.stays s left join __P__.rooms r on r.id = s.room_id left join __P__.booking_sources src on src.id = s.source_id where s.customer_id = p_customer
    union all select jsonb_build_object('at', o.created_at, 'kind', 'web', 'what', 'Ordered on the website: ' || coalesce(o.package_name, 'a package'),
        'detail', concat_ws('. ', o.price_thb || ' THB', case when o.start_on is not null then 'Starting ' || to_char(o.start_on, 'FMDD Mon YYYY') end,
          case when o.paid_at is not null then 'Paid ' || to_char(o.paid_at at time zone 'Asia/Bangkok', 'FMDD Mon HH24:MI') else 'Status: ' || o.status end, nullif(o.note, '')))
      from __P__.web_pkg_orders o where o.customer_id = p_customer
    union all select jsonb_build_object('at', p.created_at, 'kind', 'package', 'what', 'Package: ' || p.package_name,
        'detail', concat_ws('. ', p.price_thb || ' THB', 'Bought ' || to_char(p.purchased_on, 'FMDD Mon YYYY'),
          case when p.ordered_in_app then 'In the app' when exists (select 1 from __P__.web_pkg_orders w where w.purchase_id = p.id) then 'On the website' when p.stay_id is not null or to_jsonb(p)->>'for_stay' is not null then 'With the room booking' when exists (select 1 from __P__.payments q where q.purchase_id = p.id and q.stripe_session is not null) then 'Paid online' else 'At the desk' end,
          case when p.method is not null then 'Paid by ' || p.method end, case when p.sold_by is not null then 'By ' || (select name from __P__.staff where id = p.sold_by) end,
          case when p.starts_on is not null then 'Runs ' || to_char(p.starts_on, 'FMDD Mon') || coalesce(' to ' || to_char(p.expires_on, 'FMDD Mon YYYY'), '') end,
          case when p.cancelled then 'Cancelled' end, case when p.refunded_at is not null then 'Refunded ' || coalesce(p.refund_thb::text || ' THB', '') end))
      from __P__.purchases p where p.customer_id = p_customer
    union all select jsonb_build_object('at', y.at, 'kind', 'payment', 'what', case when y.amount_thb < 0 then 'Refund ' || (-y.amount_thb) || ' THB' else 'Paid ' || y.amount_thb || ' THB' end || ' by ' || y.method,
        'detail', coalesce((select k.package_name from __P__.purchases k where k.id = y.purchase_id), case when y.stay_id is not null then 'Room bill' when y.private_id is not null then 'Private session' end, y.note))
      from __P__.payments y where y.customer_id = p_customer and not y.voided
    union all select jsonb_build_object('at', x.created_at, 'kind', 'private', 'what', 'Private session ' || to_char(x.date, 'FMDD Mon YYYY') || coalesce(' ' || to_char(x.start_time, 'HH24:MI'), ''),
        'detail', concat_ws('. ', (select 'With ' || name from __P__.staff where id = x.coach_id), 'Status: ' || x.status, case when to_jsonb(x)->>'web' = 'true' then 'Booked online' end))
      from __P__.privates x where x.customer_id = p_customer
    union all select jsonb_build_object('at', a.created_at, 'kind', 'course', 'what', 'Got the online course ' || coalesce(k.title, ''), 'detail', a.source)
      from __P__.course_access a left join __P__.courses k on k.id = a.course_id where a.customer_id = p_customer
    union all select jsonb_build_object('at', max(g.done_at), 'kind', 'course', 'what', 'Watched ' || count(*) || ' course lesson' || case when count(*) = 1 then '' else 's' end, 'detail', null)
      from __P__.course_progress g where g.customer_id = p_customer and g.done having count(*) > 0
    union all select jsonb_build_object('at', so.created_at, 'kind', 'shop', 'what', 'Shop order #' || so.number || ', ' || so.total_thb || ' THB', 'detail', concat_ws('. ', 'Status: ' || so.status, case when to_jsonb(so)->>'web' = 'true' then 'Ordered in the app' end, so.method))
      from __P__.shop_orders so where so.customer_id = p_customer
    union all select jsonb_build_object('at', ab.created_at, 'kind', 'agency', 'what', 'Agency booking: ' || coalesce(ab.product, ab.kind), 'detail', concat_ws('. ', ab.source_name, ab.ref, to_char(ab.date, 'FMDD Mon YYYY'), ab.people || ' people'))
      from __P__.agency_bookings ab where ab.customer_id = p_customer
    union all select jsonb_build_object('at', coalesce(m.sent_at, m.created_at), 'kind', 'email', 'what', 'Email: ' || m.subject, 'detail', m.status)
      from __P__.sent_emails m where m.customer_id = p_customer
    union all select jsonb_build_object('at', min(ch.checked_in_at), 'kind', 'visit', 'what', 'First visit', 'detail', null) from __P__.checkins ch where ch.customer_id = p_customer having count(*) > 0
    union all select jsonb_build_object('at', max(ch.checked_in_at), 'kind', 'visit', 'what', 'Last visit (' || count(*) || ' in all)', 'detail', null) from __P__.checkins ch where ch.customer_id = p_customer having count(*) > 0
    union all select jsonb_build_object('at', pa.sent_at, 'kind', 'app', 'what', 'Sent the About you form', 'detail', pa.sent_to) from __P__.prearrival pa where pa.customer_id = p_customer and pa.sent_at is not null
    union all select jsonb_build_object('at', pa.opened_at, 'kind', 'app', 'what', 'Opened the About you form', 'detail', null) from __P__.prearrival pa where pa.customer_id = p_customer and pa.opened_at is not null
    union all select jsonb_build_object('at', pa.done_at, 'kind', 'app', 'what', 'Filled in the About you form', 'detail', case when pa.arrival is not null then 'Arriving ' || to_char(pa.arrival, 'FMDD Mon YYYY') end) from __P__.prearrival pa where pa.customer_id = p_customer and pa.done_at is not null
    union all select jsonb_build_object('at', ht.created_at, 'kind', 'chat', 'what', 'Started a chat', 'detail', ht.title) from __P__.chats ht where ht.customer_id = p_customer
    union all select jsonb_build_object('at', iv.created_at, 'kind', 'invoice', 'what', 'Invoice ' || iv.number || ', ' || iv.total || ' THB', 'detail', 'Status: ' || iv.status) from __P__.invoices iv where iv.customer_id = p_customer
    union all select jsonb_build_object('at', fa.created_at, 'kind', 'fighter', 'what', 'Applied to fight for the gym', 'detail', 'Status: ' || fa.status) from __P__.fighter_applications fa where fa.customer_id = p_customer
    union all select jsonb_build_object('at', n.created_at, 'kind', 'notice', 'what', n.title, 'detail', n.detail) from __P__.notices n where n.customer_id = p_customer and n.kind <> 'prearrival'
    ) x where e->>'at' is not null;
  ok := __Q__.health_can(p_customer);
  if ok then
    hl := jsonb_build_object(
      'file', (select to_jsonb(f) - 'photo' from __P__.member_file f where f.customer_id = p_customer),
      'intake', (select jsonb_strip_nulls(jsonb_build_object('injury', coalesce(ci.answers, pa.answers)->>'injury', 'injury_where', coalesce(ci.answers, pa.answers)->>'injury_where', 'injury_note', coalesce(ci.answers, pa.answers)->>'injury_note', 'allergies', coalesce(ci.answers, pa.answers)->>'allergies'))
        from (select 1) one left join __P__.customer_intake ci on ci.customer_id = p_customer left join __P__.prearrival pa on pa.customer_id = p_customer),
      'marks', coalesce((select jsonb_agg(jsonb_build_object('kind', h.kind, 'value', h.value, 'value2', h.value2, 'at', h.at, 'note', h.note) order by h.at desc) from (select * from __P__.health_marks where customer_id = p_customer and not removed order by at desc limit 40) h), '[]'::jsonb),
      'docs', coalesce((select jsonb_agg(jsonb_build_object('name', d.name, 'kind', d.kind, 'at', d.created_at) order by d.created_at desc) from __P__.member_docs d where d.customer_id = p_customer and not d.removed), '[]'::jsonb),
      'notes', (select count(*) from __P__.member_notes n where n.customer_id = p_customer and not n.removed));
    if __Q__.my_staff_id() is not null then insert into __P__.member_file_views (customer_id, staff_id) values (p_customer, __Q__.my_staff_id()); end if;
  end if;
  return jsonb_build_object('customer', to_jsonb(c), 'signed_up', u.created_at, 'last_sign_in', u.last_sign_in_at,
    'spent', (select coalesce(sum(amount_thb), 0) from __P__.payments where customer_id = p_customer and not voided),
    'visits', (select count(*) from __P__.checkins where customer_id = p_customer),
    'referred_by', (select a.name from __P__.affiliates a where a.id = coalesce((select affiliate_id from __P__.stays where customer_id = p_customer and affiliate_id is not null limit 1), (select affiliate_id from __P__.purchases where customer_id = p_customer and affiliate_id is not null limit 1))),
    'events', ev, 'health_ok', ok, 'health', hl);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103571, 11, 'patch', 'health_private:1103571', $TPL$revoke all on function __Q__.health_keeper_ids(), __Q__.health_keeper(), __Q__.health_can(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103572, 11, 'patch', 'health_private:1103572', $TPL$grant execute on function __Q__.health_can(uuid), __Q__.health_keeper(), __Q__.health_keeper_ids() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103573, 11, 'patch', 'health_private:1103573', $TPL$revoke all on function __P__.health_access_list(uuid), __P__.health_access_set(uuid, uuid, boolean), __P__.health_keepers_set(uuid[]), __P__.customer_info(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103574, 11, 'patch', 'health_private:1103574', $TPL$grant execute on function __P__.health_access_list(uuid), __P__.health_access_set(uuid, uuid, boolean), __P__.health_keepers_set(uuid[]), __P__.customer_info(uuid) to authenticated;$TPL$);
-- part 2 (health_private_patch.sql): the template rows of the functions that read health get the same change
update mf.template set sql = replace(replace(sql, '__Q__.coach_can(', '__Q__.health_can('), 'Only this member''s coaches and the managers can open their file.', 'Health records are private. Ask the owner to let you see them.')
  where (name in ('public.member_file_get','public.member_file_save','public.member_consent_set','public.member_note_save','public.member_note_remove','public.member_doc_add','public.member_doc_remove','public.member_doc_share','public.pangea_health_add','public.pangea_health_remove') or name like 'member_file:%')
    and sql ilike 'CREATE OR REPLACE FUNCTION%' and position('health_can' in sql) = 0;
update mf.template set sql = replace(sql, 'or __Q__.coach_can(v::uuid);', 'or (case when split_part(p_name, ''/'', 2) in (''file'', ''health'') then __Q__.health_can(v::uuid) else __Q__.coach_can(v::uuid) end);')
  where name = 'private.coach_path_ok' and sql ilike 'create or replace function%' and position('health_can' in sql) = 0;
update mf.template set sql = replace(sql, 'where h.customer_id = p_customer and not h.removed', 'where h.customer_id = p_customer and not h.removed and __Q__.health_can(p_customer)')
  where name = 'public.pangea_client' and sql ilike 'create or replace function%' and position('health_can' in sql) = 0;
update mf.template set sql = replace(sql, $r$'answers', coalesce(ci.answers, pa.answers, '{}'::jsonb),$r$,
    $r$'answers', case when __Q__.health_can(p_customer) then coalesce(ci.answers, pa.answers, '{}'::jsonb) else coalesce(ci.answers, pa.answers, '{}'::jsonb) - 'injury' - 'injury_where' - 'injury_note' end, 'health_hidden', not __Q__.health_can(p_customer),$r$)
  where name = 'public.customer_intake_get' and sql ilike 'create or replace function%' and position('health_can' in sql) = 0;
update mf.template set sql = replace(replace(sql, $r$'answers', p.answers,$r$, $r$'answers', case when __Q__.health_can(c.id) then p.answers else p.answers - 'injury' - 'injury_where' - 'injury_note' end,$r$),
    $r$'answers', coalesce(ci.answers, '{}'::jsonb),$r$, $r$'answers', case when __Q__.health_can(c.id) then coalesce(ci.answers, '{}'::jsonb) else coalesce(ci.answers, '{}'::jsonb) - 'injury' - 'injury_where' - 'injury_note' end,$r$)
  where name = 'public.prearrival_list' and sql ilike 'create or replace function%' and position('health_can' in sql) = 0;
update mf.template set sql = replace(sql, $r$'answers', coalesce(nullif(p.answers, '{}'::jsonb), ci.answers, '{}'::jsonb),$r$,
    $r$'answers', coalesce(nullif(p.answers, '{}'::jsonb), ci.answers, '{}'::jsonb) - case when __Q__.feature('health_private', true) then array['injury','injury_where','injury_note'] else array[]::text[] end,$r$)
  where name = 'public.coach_brief' and sql ilike 'create or replace function%' and position('health_private' in sql) = 0;
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'health_private:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
    for r in select sql from mf.template where sql ilike 'create or replace function%' and (position('health_can' in sql) > 0 or position('''health_private''' in sql) > 0) and name not like 'health_private:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
