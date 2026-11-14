-- Notifications each person chooses (feature notify_choice, on unless switched off): every staff member picks which phone
-- notifications they get: bookings and purchases from customers (online, in the member app, agencies) and also sales made by
-- the team (packages sold, rooms booked at the desk, every till sale). A manager can set it for anyone; anyone can set their own
-- (Messages, My notifications). People with no choice saved follow the defaults for their role (Booking notifications).
-- Messages and a coach's own privates always notify as before.

-- the kinds: private, stay, package, class, order (ordered in the app, pay at the desk), sale_package, sale_stay, sale_till
create or replace function private.push_wants(p_staff uuid, p_role text, p_kind text) returns boolean language sql stable security definer set search_path to '' as $f$
  with c as (select private.booking_push_cfg() v)
  select case when private.feature('notify_choice', true) and (c.v->'people') ? p_staff::text
      then (c.v->'people'->p_staff::text) ? p_kind
    else (c.v->'roles') ? p_role and (c.v->'kinds') ? p_kind end
  from c
$f$;

create or replace function private.push_kind(p_k text) returns text language sql immutable as $f$
  select case when p_k like 'book\_%' then substr(p_k, 6) else p_k end
$f$;

-- which bookings and sales send a notice
do $w$
declare u text := substring(pg_get_functiondef('private.booking_push_send()'::regprocedure) from 'https://[a-z0-9]+\.supabase\.co/functions/v1');
begin
  if u is null then raise exception 'booking_push_send: no functions address found'; end if;
  execute replace($b$create or replace function private.booking_push_send() returns trigger language plpgsql security definer set search_path to '' as $f$
declare k text; tok text; base text; cfg jsonb; team boolean := private.my_staff_id() is not null;
begin
  if not private.feature('booking_push', true) then return null; end if;
  if tg_table_name = 'privates' then
    if team or tg_op <> 'INSERT' or new.status in ('cancelled','done') or new.date < private.bkk_today() then return null; end if; k := 'book_private';
  elsif tg_table_name = 'stays' then
    if new.status = 'cancelled' or new.check_out < private.bkk_today() then return null; end if;
    if tg_op = 'INSERT' then if new.hold_until is not null then return null; end if;
    elsif not (old.hold_until is not null and new.hold_until is null) then return null; end if;
    k := case when team then 'sale_stay' else 'book_stay' end;
  elsif tg_table_name = 'purchases' then
    if new.for_stay is not null or new.stay_id is not null or coalesce(new.cancelled, false) then return null; end if;
    if team then
      if tg_op <> 'INSERT' or coalesce(new.price_thb, 0) <= 0 then return null; end if; k := 'sale_package';
    elsif tg_op = 'INSERT' and coalesce(new.ordered_in_app, false) and not coalesce(new.paid, false) then k := 'book_order';
    else
      if not coalesce(new.paid, false) or (tg_op = 'UPDATE' and coalesce(old.paid, false)) then return null; end if; k := 'book_package';
    end if;
  elsif tg_table_name = 'agency_bookings' then
    if team or tg_op <> 'INSERT' or new.kind <> 'class' or new.status = 'cancelled' then return null; end if; k := 'book_class';
  elsif tg_table_name = 'shop_orders' then
    if new.paid_at is null or (tg_op = 'UPDATE' and old.paid_at is not null) or new.refunded_at is not null or coalesce(new.total_thb, 0) <= 0 then return null; end if;
    k := 'sale_till';
  end if;
  if k is null then return null; end if;
  cfg := private.booking_push_cfg();
  if not ((k like 'book\_%' and coalesce(cfg->>'email', '') <> '' and (cfg->'kinds') ? private.push_kind(k))
    or exists (select 1 from public.push_subs x join public.staff st on st.id = x.staff_id where x.off_at is null and st.active
               and private.push_wants(st.id, st.role, private.push_kind(k)))) then return null; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  select value into base from private.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, '__FNURL__') || '/chat',
    body := jsonb_build_object('mode', 'push', 'kind', k, 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;$b$, '__FNURL__', u);
end $w$;

drop trigger if exists shop_orders_booking_push on public.shop_orders;
create trigger shop_orders_booking_push after insert or update of paid_at on public.shop_orders for each row execute function private.booking_push_send();

-- what the notice says and whose phones get it
create or replace function private.booking_push(p_kind text, p_id uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare cfg jsonb := private.booking_push_cfg(); kk text := private.push_kind(p_kind); t text; b text; url text := '#today';
  p public.privates; s public.stays; u public.purchases; a public.agency_bookings; o public.shop_orders; who text; src text; byname text;
begin
  if p_kind = 'book_private' then
    select * into p from public.privates where id = p_id; if p.id is null then return null; end if;
    who := coalesce((select c.name from public.customers c where c.id = p.customer_id and not coalesce(c.is_agency,false)), p.guest_name, 'A customer');
    src := (select x.name from public.booking_sources x where x.id = p.source_id);
    t := 'จองไพรเวทใหม่ / New private booked';
    b := who || ': ' || to_char(p.date, 'Dy DD Mon') || ' ' || to_char(p.start_time, 'HH24:MI') || coalesce(', ' || p.minutes || ' min', '')
      || coalesce(' with ' || (select st.name from public.staff st where st.id = p.coach_id), ', any coach') || coalesce(' (' || src || ')', '')
      || case when p.paid then ', paid' else '' end || '.';
    url := '#privates';
  elsif p_kind in ('book_stay', 'sale_stay') then
    select * into s from public.stays where id = p_id; if s.id is null then return null; end if;
    who := coalesce((select c.name from public.customers c where c.id = s.customer_id), 'A guest');
    src := (select x.name from public.booking_sources x where x.id = s.source_id);
    t := case when p_kind = 'sale_stay' then 'ทีมจองห้อง / Room booked by the team' else 'จองห้องใหม่ / New room booking' end;
    b := who || ': ' || coalesce((select r.name from public.rooms r where r.id = s.room_id), 'a room') || ', ' || to_char(s.check_in, 'DD Mon') || ' to ' || to_char(s.check_out, 'DD Mon')
      || coalesce(', ' || nullif(s.guests, ''), '') || coalesce(' (' || src || ')', '')
      || coalesce(', paid ' || to_char(nullif((select sum(x.amount_thb) from public.payments x where not x.voided and (x.stay_id = s.id or x.purchase_id in (select q.id from public.purchases q where q.for_stay = s.id))), 0), 'FM999,999,990') || ' THB', '') || '.';
    url := '#stays';
  elsif p_kind in ('book_package', 'book_order', 'sale_package') then
    select * into u from public.purchases where id = p_id; if u.id is null then return null; end if;
    who := coalesce((select c.name from public.customers c where c.id = u.customer_id), 'A customer');
    t := case p_kind when 'book_order' then 'สั่งในแอป รอชำระ / Ordered in the app, to pay at the desk'
      when 'sale_package' then 'ขายแพ็กเกจ / Package sold' else 'ซื้อแพ็กเกจออนไลน์ / Package bought online' end;
    b := who || ': ' || coalesce(u.package_name, 'a package') || case when coalesce(u.price_thb,0) > 0 then ', ' || to_char(u.price_thb, 'FM999,990') || ' THB' else '' end
      || case when p_kind = 'sale_package' and not coalesce(u.paid, false) and coalesce(u.paid_thb, 0) = 0 then ', not paid yet' else '' end
      || coalesce(', starts ' || to_char(u.starts_on, 'DD Mon'), '') || '.';
    url := '#customers';
  elsif p_kind = 'book_class' then
    select * into a from public.agency_bookings where id = p_id; if a.id is null then return null; end if;
    t := 'จองคลาสใหม่ / New class booking';
    b := coalesce(a.guest_name, 'A guest') || case when a.people > 1 then ', ' || a.people || ' people' else '' end || ': ' || coalesce(to_char(a.date, 'Dy DD Mon'), '') || coalesce(' ' || left(a.time::text, 5), '')
      || coalesce(' (' || a.source_name || ')', '') || '.';
  elsif p_kind = 'sale_till' then
    select * into o from public.shop_orders where id = p_id; if o.id is null then return null; end if;
    byname := (select st.name from public.staff st where st.id = o.staff_id);
    t := 'ขายหน้าร้าน / Till sale';
    b := to_char(o.total_thb, 'FM999,990') || ' THB' || coalesce(', ' || nullif(o.method, ''), '')
      || coalesce(': ' || (select string_agg(i.qty || ' x ' || i.name, ', ') from public.shop_order_items i where i.order_id = o.id and not coalesce(i.removed, false)), '')
      || coalesce(' (' || byname || ')', '') || '.';
    url := '#shop';
  else return null; end if;
  return jsonb_build_object('title', t, 'body', left(b, 180), 'tag', p_kind || '-' || p_id, 'url', url,
    'email', case when p_kind like 'book\_%' and (cfg->'kinds') ? kk then nullif(cfg->>'email', '') end,
    'from', (select case when w.value ~ '^\s*\{' then w.value::jsonb->>'from' end from public.app_settings w where w.key = 'welcome_email'),
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'p256dh', x.p256dh, 'auth', x.auth))
      from public.push_subs x join public.staff st on st.id = x.staff_id where x.off_at is null and st.active and private.push_wants(st.id, st.role, kk)), '[]'::jsonb));
end $f$;

-- team sales go the same way as bookings
do $p$
declare d text;
begin
  d := pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure);
  if position('sale\_%' in d) = 0 then
    execute replace(d, $x$if p_kind like 'book\_%' then$x$, $x$if p_kind like 'book\_%' or p_kind like 'sale\_%' then$x$);
    if position('sale\_%' in pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure)) = 0 then raise exception 'push_targets patch did not apply'; end if;
  end if;
end $p$;

-- settings: the defaults by role, and each person's own choice
create or replace function private.push_kinds_ok(p jsonb) returns jsonb language sql immutable as $f$
  select coalesce((select jsonb_agg(distinct k) from jsonb_array_elements_text(coalesce(p, '[]'::jsonb)) k
    where k in ('private','stay','package','class','order','sale_package','sale_stay','sale_till')), '[]'::jsonb)
$f$;

create or replace function public.booking_push_settings() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return private.booking_push_cfg() || jsonb_build_object('staff', coalesce((select jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name, 'role', st.role,
      'phone', exists (select 1 from public.push_subs x where x.staff_id = st.id and x.off_at is null)) order by st.name)
    from public.staff st where st.active), '[]'::jsonb));
end $f$;

create or replace function public.booking_push_settings_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v jsonb; ppl jsonb := '{}'::jsonb; k text; x jsonb;
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  if jsonb_typeof(p->'people') = 'object' then
    for k, x in select * from jsonb_each(p->'people') loop
      if exists (select 1 from public.staff st where st.id::text = k) then ppl := ppl || jsonb_build_object(k, private.push_kinds_ok(x)); end if;
    end loop;
  else ppl := coalesce(private.booking_push_cfg()->'people', '{}'::jsonb); end if;
  v := jsonb_build_object(
    'roles', coalesce((select jsonb_agg(r) from jsonb_array_elements_text(coalesce(p->'roles','[]'::jsonb)) r where r in ('manager','front_desk','resort','kitchen','coach','admin')), '[]'::jsonb),
    'kinds', private.push_kinds_ok(p->'kinds'),
    'email', case when coalesce(p->>'email','') ~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then lower(trim(p->>'email')) end,
    'people', ppl);
  insert into public.app_settings(key, value) values ('booking_push', v::text) on conflict (key) do update set value = excluded.value;
  return v;
end $f$;

-- anyone on the team: their own choice
create or replace function public.my_push_kinds() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare me uuid := private.my_staff_id(); c jsonb := private.booking_push_cfg(); r text := private.staff_role();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  return jsonb_build_object('own', (c->'people') ? me::text, 'role', r,
    'kinds', case when (c->'people') ? me::text then c->'people'->me::text
      when (c->'roles') ? r then c->'kinds' else '[]'::jsonb end);
end $f$;

create or replace function public.my_push_kinds_save(p_kinds jsonb) returns void language plpgsql security definer set search_path to '' as $f$
declare me uuid := private.my_staff_id(); c jsonb;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if not private.feature('notify_choice', true) then raise exception 'Switched off in Settings, Features.'; end if;
  c := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'booking_push'), '{}'::jsonb);
  c := jsonb_set(c, '{people}', coalesce(c->'people', '{}'::jsonb) || jsonb_build_object(me::text,
    case when p_kinds is null then null else private.push_kinds_ok(p_kinds) end));
  c := jsonb_set(c, '{people}', jsonb_strip_nulls(c->'people'));
  insert into public.app_settings(key, value) values ('booking_push', c::text) on conflict (key) do update set value = excluded.value;
end $f$;

revoke all on function public.my_push_kinds() from public, anon;
revoke all on function public.my_push_kinds_save(jsonb) from public, anon;
grant execute on function public.my_push_kinds() to authenticated;
grant execute on function public.my_push_kinds_save(jsonb) to authenticated;

notify pgrst, 'reload schema';
