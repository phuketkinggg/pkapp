-- One customer, one file (feature one_customer, on by default).
-- 1. Merging two customers now moves everything: payments, invoices, food plans, notes, health, courses, coaching,
--    grades, emails and every other record that belongs to a customer, not only stays, packages, privates and shop orders.
--    It finds them by itself, so anything added later is moved too. Where the kept customer already has the one record a
--    customer can have (for example a member file), the merged one keeps its copy and the count says so.
-- 2. When a package, private, stay or shop order moves to another customer, its payments, check-ins and food plans move too.
-- 3. Payments already left on the wrong customer are fixed.

create or replace function private.cust_move_all(p_keep uuid, p_drop uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare r record; n int; left_ int; tot jsonb := '{}'::jsonb; kept jsonb := '{}'::jsonb; t text; rid tid;
begin
  for r in
    select c.conrelid::regclass::text tbl, a.attname::text col
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    join pg_class cl on cl.oid = c.conrelid join pg_namespace ns on ns.oid = cl.relnamespace
    where c.contype = 'f' and c.confrelid = 'public.customers'::regclass and ns.nspname = 'public' and array_length(c.conkey, 1) = 1
      and cl.relname not in ('chats', 'chat_members')  -- merge_customers moves chats itself (one front desk chat each)
    order by 1, 2
  loop
    t := r.tbl || '.' || r.col; n := 0; left_ := 0;
    begin
      execute format('update %s set %I = $1 where %I = $2', r.tbl, r.col, r.col) using p_keep, p_drop;
      get diagnostics n = row_count;
    exception when unique_violation then
      -- one row at a time: rows the kept customer already has stay on the merged one
      for rid in execute format('select ctid from %s where %I = $1', r.tbl, r.col) using p_drop loop
        begin
          execute format('update %s set %I = $1 where ctid = $2', r.tbl, r.col) using p_keep, rid;
          n := n + 1;
        exception when unique_violation then left_ := left_ + 1;
        end;
      end loop;
    end;
    if n > 0 then tot := tot || jsonb_build_object(t, n); end if;
    if left_ > 0 then kept := kept || jsonb_build_object(t, left_); end if;
  end loop;
  return jsonb_build_object('moved', tot, 'already_had', kept);
end $f$;
revoke all on function private.cust_move_all(uuid, uuid) from public, anon, authenticated;

-- merge_customers: after its own steps (desk chats, logins, details), move everything else too
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.merge_customers(uuid,uuid)') is null then return; end if;
  d := pg_get_functiondef('public.merge_customers(uuid,uuid)'::regprocedure);
  if position('cust_move_all' in d) = 0 then
    n := replace(d, '  -- fill in what the kept customer is missing',
      '  -- everything else that belongs to a customer (payments, invoices, notes, health, courses and more)
  if private.feature(''one_customer'', true) then n := n || jsonb_build_object(''all'', private.cust_move_all(p_keep, p_drop)); end if;

  -- fill in what the kept customer is missing');
    if n = d then raise notice 'one_customer: merge_customers is different, skipped'; else execute n; end if;
  end if;
end $p$;

-- when a package, private, stay or shop order moves to another customer, what hangs off it follows
create or replace function private.cust_follow() returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  if new.customer_id is not distinct from old.customer_id or new.customer_id is null or not private.feature('one_customer', true) then return new; end if;
  if tg_table_name = 'purchases' then
    update public.payments set customer_id = new.customer_id where purchase_id = new.id and (customer_id is null or customer_id = old.customer_id);
    update public.checkins set customer_id = new.customer_id where purchase_id = new.id and customer_id is not distinct from old.customer_id;
    update public.food_plans set customer_id = new.customer_id where purchase_id = new.id and customer_id is not distinct from old.customer_id;
  elsif tg_table_name = 'privates' then
    update public.payments set customer_id = new.customer_id where private_id = new.id and (customer_id is null or customer_id = old.customer_id);
  elsif tg_table_name = 'stays' then
    update public.payments set customer_id = new.customer_id where stay_id = new.id and (customer_id is null or customer_id = old.customer_id);
    update public.food_plans set customer_id = new.customer_id where stay_id = new.id and customer_id is not distinct from old.customer_id;
  end if;
  return new;
end $f$;
revoke all on function private.cust_follow() from public, anon, authenticated;
drop trigger if exists purchases_cust_follow on public.purchases;
create trigger purchases_cust_follow after update of customer_id on public.purchases for each row execute function private.cust_follow();
drop trigger if exists privates_cust_follow on public.privates;
create trigger privates_cust_follow after update of customer_id on public.privates for each row execute function private.cust_follow();
drop trigger if exists stays_cust_follow on public.stays;
create trigger stays_cust_follow after update of customer_id on public.stays for each row execute function private.cust_follow();

-- payments left on no one, or on the old customer, after a package or private moved
update public.payments p set customer_id = k.customer_id from public.purchases k
  where k.id = p.purchase_id and k.customer_id is not null and p.customer_id is distinct from k.customer_id and private.feature('one_customer', true);
update public.payments p set customer_id = x.customer_id from public.privates x
  where x.id = p.private_id and x.customer_id is not null and p.customer_id is distinct from x.customer_id and private.feature('one_customer', true);

-- removing a customer: someone with money records (payments, invoices, shop sales, web orders) is kept as
-- "Deleted customer" with no name or contact details, so the money stays on one record instead of losing its customer
create or replace function private.cust_has_money(p uuid) returns boolean language plpgsql stable security definer set search_path = '' as $f$
declare t text; c text; hit boolean;
begin
  foreach t in array array['payments','invoices','shop_orders','web_pkg_orders','agency_bookings','affiliates'] loop
    if to_regclass('public.' || t) is not null then
      execute format('select exists (select 1 from public.%I where customer_id = $1)', t) into hit using p;
      if hit then return true; end if;
    end if;
  end loop;
  return false;
end $f$;
revoke all on function private.cust_has_money(uuid) from public, anon, authenticated;

do $p$
declare d text; n text;
begin
  if to_regprocedure('public.customer_remove(uuid)') is null then return; end if;
  d := pg_get_functiondef('public.customer_remove(uuid)'::regprocedure);
  if position('cust_has_money' in d) = 0 then
    n := replace(d, E'  begin\n    delete from public.customers where id = p_id;',
      E'  if private.feature(''one_customer'', true) and private.cust_has_money(p_id) then null; else\n  begin\n    delete from public.customers where id = p_id;');
    n := replace(n, E'  exception when foreign_key_violation then null;\n  end;\n', E'  exception when foreign_key_violation then null;\n  end;\n  end if;\n');
    if position('cust_has_money' in n) = 0 or position(E'end if;\n  foreach' in n) = 0 then raise notice 'one_customer: customer_remove is different, skipped';
    else execute n; end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
