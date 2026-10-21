-- Access by department and by right.
-- Owner (role manager): everything, as before.
-- Admin (role admin): works like a manager, but only in the departments ticked (gym, spa, resort, cafe)
--   and only with the rights ticked: edit (change things), refunds, money (accounts, receipts, invoices),
--   staff (staff, hours, pay, commission), settings (settings, packages, prices, website), marketing.
-- Front desk (role front_desk): can be limited to departments too (the app shows only those parts).
-- staff.access = {"areas":["gym","spa","resort","cafe"],"perms":["edit","refunds","money","staff","settings","marketing"]}
-- No areas ticked means all departments.

alter table public.staff add column if not exists access jsonb;
alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (role = any (array['manager','admin','front_desk','coach','resort','housekeeping','kitchen','investor','maintenance']));

-- the database treats an admin as a manager; the limits come from private.can and private.area_ok
create or replace function private.staff_role() returns text language sql stable security definer set search_path = '' as $f$
  select case when s.role = 'admin' then 'manager' else s.role end from public.staff s where s.user_id = (select auth.uid()) and s.active limit 1
$f$;

create or replace function private.real_role() returns text language sql stable security definer set search_path = '' as $f$
  select s.role from public.staff s where s.user_id = (select auth.uid()) and s.active limit 1
$f$;

-- a right: owners have all; admins only those ticked; the system itself (no signed in user) has all
create or replace function private.can(p text) returns boolean language sql stable security definer set search_path = '' as $f$
  select case when (select auth.uid()) is null then true
    else coalesce((select case when s.role = 'manager' then true when s.role = 'admin' then coalesce(s.access->'perms' ? p, false) else false end
                   from public.staff s where s.user_id = (select auth.uid()) and s.active limit 1), false) end
$f$;

-- a department, from a business and a department name as used in Accounts
create or replace function private.area_ok(p_b text, p_dep text) returns boolean language sql stable security definer set search_path = '' as $f$
  with a as (select case when (select auth.uid()) is null then null
                         else (select case when s.role in ('admin','front_desk') and jsonb_array_length(coalesce(s.access->'areas','[]'::jsonb)) > 0 then s.access->'areas' end
                               from public.staff s where s.user_id = (select auth.uid()) and s.active limit 1) end x)
  select case when (select x from a) is null then true else
    (coalesce(p_dep,'') = 'Spa' and (select x from a) ? 'spa')
    or (coalesce(p_dep,'') ilike '%cafe%' and (select x from a) ? 'cafe')
    or (coalesce(p_b,'') not ilike '%gym%' and coalesce(p_dep,'') <> 'Spa' and coalesce(p_dep,'') not ilike '%cafe%' and (select x from a) ? 'resort')
    or (coalesce(p_b,'') ilike '%gym%' and coalesce(p_dep,'') <> 'Spa' and coalesce(p_dep,'') not ilike '%cafe%' and (select x from a) ? 'gym') end
$f$;

-- view only admins: nothing in the main tables can be changed
create or replace function private.guard_view_only() returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  -- opening a customer marks them as seen; that is not a change
  if tg_table_name = 'customers' and tg_op = 'UPDATE' and (to_jsonb(new) - 'seen_at') = (to_jsonb(old) - 'seen_at') then return new; end if;
  if (select auth.uid()) is not null and exists (select 1 from public.staff s where s.user_id = (select auth.uid()) and s.active and s.role = 'admin' and not coalesce(s.access->'perms' ? 'edit', false)) then
    raise exception 'Your access is view only. Ask the owner if you need to change things.';
  end if;
  return coalesce(new, old);
end $f$;

do $$
declare t text;
begin
  foreach t in array array['customers','purchases','privates','stays','payments','room_charges','shop_orders','packages','classes','invoices','expense_receipts','holidays','booking_sources','shop_products','app_settings'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists zz_view_only on public.%I', t);
      execute format('create trigger zz_view_only before insert or update or delete on public.%I for each row execute function private.guard_view_only()', t);
    end if;
  end loop;
end $$;

-- staff: only the owner, or an admin with the Staff right, changes staff; only the owner makes owners and admins
create or replace function private.guard_staff_change() returns trigger language plpgsql security definer set search_path = '' as $f$
declare r text := private.real_role();
begin
  if (select auth.uid()) is null or r = 'manager' then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and new.role is not distinct from old.role and new.access is not distinct from old.access and new.commission_pct is not distinct from old.commission_pct
     and new.active is not distinct from old.active and new.email is not distinct from old.email and new.user_id is not distinct from old.user_id then return new; end if;
  if not private.can('staff') then raise exception 'Only the owner, or an admin with staff rights, can change staff.'; end if;
  if tg_op <> 'INSERT' and old.role in ('manager','admin') then raise exception 'Only the owner can change owners and admins.'; end if;
  if tg_op <> 'DELETE' and (new.role in ('manager','admin') or (tg_op = 'UPDATE' and new.access is distinct from old.access)) then raise exception 'Only the owner can make owners and admins or change access.'; end if;
  return coalesce(new, old);
end $f$;
drop trigger if exists zz_staff_guard on public.staff;
create trigger zz_staff_guard before insert or update or delete on public.staff for each row execute function private.guard_staff_change();

-- PIN approvals and phone alerts: admins too (approvals only with the refunds right)
create or replace function private.shop_pin_owner(p_pin text) returns uuid language sql stable security definer set search_path = '' as $f$
  select s.id from public.staff s where s.active and (s.role in ('manager','resort') or (s.role = 'admin' and coalesce(s.access->'perms' ? 'refunds', false))) and s.pin_hash is not null
    and coalesce(p_pin,'') <> '' and s.pin_hash = extensions.crypt(p_pin, s.pin_hash) limit 1
$f$;

do $$
declare d text; n text; f text;
begin
  d := pg_get_functiondef('public.web_push_targets()'::regprocedure);
  n := replace(d, 's.role in (''manager'',''front_desk'',''resort'')', 's.role in (''manager'',''admin'',''front_desk'',''resort'')');
  if n <> d then execute n; end if;

  -- money: accounts, receipts, invoices, the investor view
  foreach f in array array['public.acc_checks_list(date,date)','public.acc_entry_save(jsonb)','public.acc_entry_void(uuid)','public.acc_feed_link(boolean)','public.acc_recurring_save(jsonb)',
      'public.accounts_data(date,date)','public.invoices_list()','public.invoice_save(jsonb)','public.invoice_paid(uuid,text,date,text,boolean)','public.invoice_unpaid(uuid)','public.invoice_cancel(uuid)',
      'public.receipts_list(date,date)','public.receipt_save(jsonb)','public.investor_dashboard(date,date)'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(to_regprocedure(f));
    if position('private.can(' in d) > 0 or position('<> ''manager''' in d) = 0 then continue; end if;
    n := regexp_replace(d, E'\nbegin\n', E'\nbegin\n  if not private.can(''money'') then raise exception ''Your access does not include money and accounts.''; end if;\n');
    if n <> d then execute n; end if;
  end loop;
  -- staff pay
  foreach f in array array['public.commission_pay(uuid,date,date,text)','public.commission_undo(uuid)','public.staff_hours(date,date)'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(to_regprocedure(f));
    if position('private.can(' in d) > 0 then continue; end if;
    n := regexp_replace(d, E'\nbegin\n', E'\nbegin\n  if private.real_role() = ''admin'' and not private.can(''staff'') then raise exception ''Your access does not include staff and pay.''; end if;\n');
    if n <> d then execute n; end if;
  end loop;

  -- Accounts shows only the departments an admin has
  d := pg_get_functiondef('public.accounts_data(date,date)'::regprocedure);
  if position('area_ok' in d) = 0 then
    n := replace(d, 'from private.acc_lines(p_from, p_to) x),', 'from private.acc_lines(p_from, p_to) x where private.area_ok(x.b, x.dep)),');
    n := replace(n, 'from private.acc_lines((date_trunc(''month'', v_today) - interval ''11 months'')::date, v_today) y group by 1,2)', 'from private.acc_lines((date_trunc(''month'', v_today) - interval ''11 months'')::date, v_today) y where private.area_ok(y.b, y.dep) group by 1,2)');
    n := replace(n, '''room_sales'', (select', '''room_sales'', (select case when not private.area_ok(''Pangea Resort'',''Rooms'') then 0 else (select');
    n := replace(n, 'from public.stays s where s.status <> ''cancelled'' and s.check_in <= p_to and s.check_out > p_from));', 'from public.stays s where s.status <> ''cancelled'' and s.check_in <= p_to and s.check_out > p_from) end));');
    if (select count(*) from regexp_matches(n, 'area_ok', 'g')) < 3 then raise exception 'accounts_data not changed'; end if;
    execute n;
  end if;
  d := pg_get_functiondef('public.acc_checks_list(date,date)'::regprocedure);
  if position('area_ok' in d) = 0 then
    n := replace(d, 'from private.acc_checks(p_from, p_to) x)', 'from private.acc_checks(p_from, p_to) x where private.area_ok(x.b, null))');
    if n <> d then execute n; end if;
  end if;
end $$;

-- the app reads the access column (the staff table has column by column read rights)
grant select (access) on public.staff to authenticated;
