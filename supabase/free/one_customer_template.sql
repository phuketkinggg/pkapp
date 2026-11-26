delete from mf.template where name like 'one_customer:%';
insert into mf.template (ord, phase, kind, name, sql) values (405501, 4, 'patch', 'one_customer:405501', $TPL$create or replace function __Q__.cust_move_all(p_keep uuid, p_drop uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare r record; n int; left_ int; tot jsonb := '{}'::jsonb; kept jsonb := '{}'::jsonb; t text; rid tid;
begin
  for r in
    select c.conrelid::regclass::text tbl, a.attname::text col
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    join pg_class cl on cl.oid = c.conrelid join pg_namespace ns on ns.oid = cl.relnamespace
    where c.contype = 'f' and c.confrelid = '__P__.customers'::regclass and ns.nspname = 'public' and array_length(c.conkey, 1) = 1
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
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199601, 11, 'patch', 'one_customer:1199601', $TPL$revoke all on function __Q__.cust_move_all(uuid, uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004101, 10, 'patch', 'one_customer:1004101', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.merge_customers(uuid,uuid)') is null then return; end if;
  d := pg_get_functiondef('__P__.merge_customers(uuid,uuid)'::regprocedure);
  if position('cust_move_all' in d) = 0 then
    n := replace(d, '  -- fill in what the kept customer is missing',
      '  -- everything else that belongs to a customer (payments, invoices, notes, health, courses and more)
  if __Q__.feature(''one_customer'', true) then n := n || jsonb_build_object(''all'', __Q__.cust_move_all(p_keep, p_drop)); end if;

  -- fill in what the kept customer is missing');
    if n = d then raise notice 'one_customer: merge_customers is different, skipped'; else execute n; end if;
  end if;
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405502, 4, 'patch', 'one_customer:405502', $TPL$create or replace function __Q__.cust_follow() returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  if new.customer_id is not distinct from old.customer_id or new.customer_id is null or not __Q__.feature('one_customer', true) then return new; end if;
  if tg_table_name = 'purchases' then
    update __P__.payments set customer_id = new.customer_id where purchase_id = new.id and (customer_id is null or customer_id = old.customer_id);
    update __P__.checkins set customer_id = new.customer_id where purchase_id = new.id and customer_id is not distinct from old.customer_id;
    update __P__.food_plans set customer_id = new.customer_id where purchase_id = new.id and customer_id is not distinct from old.customer_id;
  elsif tg_table_name = 'privates' then
    update __P__.payments set customer_id = new.customer_id where private_id = new.id and (customer_id is null or customer_id = old.customer_id);
  elsif tg_table_name = 'stays' then
    update __P__.payments set customer_id = new.customer_id where stay_id = new.id and (customer_id is null or customer_id = old.customer_id);
    update __P__.food_plans set customer_id = new.customer_id where stay_id = new.id and customer_id is not distinct from old.customer_id;
  end if;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199602, 11, 'patch', 'one_customer:1199602', $TPL$revoke all on function __Q__.cust_follow() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903701, 9, 'patch', 'one_customer:903701', $TPL$drop trigger if exists purchases_cust_follow on __P__.purchases;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903702, 9, 'patch', 'one_customer:903702', $TPL$create trigger purchases_cust_follow after update of customer_id on __P__.purchases for each row execute function __Q__.cust_follow();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903703, 9, 'patch', 'one_customer:903703', $TPL$drop trigger if exists privates_cust_follow on __P__.privates;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903704, 9, 'patch', 'one_customer:903704', $TPL$create trigger privates_cust_follow after update of customer_id on __P__.privates for each row execute function __Q__.cust_follow();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903705, 9, 'patch', 'one_customer:903705', $TPL$drop trigger if exists stays_cust_follow on __P__.stays;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903706, 9, 'patch', 'one_customer:903706', $TPL$create trigger stays_cust_follow after update of customer_id on __P__.stays for each row execute function __Q__.cust_follow();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004102, 10, 'patch', 'one_customer:1004102', $TPL$update __P__.payments p set customer_id = k.customer_id from __P__.purchases k
  where k.id = p.purchase_id and k.customer_id is not null and p.customer_id is distinct from k.customer_id and __Q__.feature('one_customer', true);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004103, 10, 'patch', 'one_customer:1004103', $TPL$update __P__.payments p set customer_id = x.customer_id from __P__.privates x
  where x.id = p.private_id and x.customer_id is not null and p.customer_id is distinct from x.customer_id and __Q__.feature('one_customer', true);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405503, 4, 'patch', 'one_customer:405503', $TPL$create or replace function __Q__.cust_has_money(p uuid) returns boolean language plpgsql stable security definer set search_path = '' as $f$
declare t text; c text; hit boolean;
begin
  foreach t in array array['payments','invoices','shop_orders','web_pkg_orders','agency_bookings','affiliates'] loop
    if to_regclass('public.' || t) is not null then
      execute format('select exists (select 1 from public.%I where customer_id = $1)', t) into hit using p;
      if hit then return true; end if;
    end if;
  end loop;
  return false;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199603, 11, 'patch', 'one_customer:1199603', $TPL$revoke all on function __Q__.cust_has_money(uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004104, 10, 'patch', 'one_customer:1004104', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.customer_remove(uuid)') is null then return; end if;
  d := pg_get_functiondef('__P__.customer_remove(uuid)'::regprocedure);
  if position('cust_has_money' in d) = 0 then
    n := replace(d, E'  begin\n    delete from __P__.customers where id = p_id;',
      E'  if __Q__.feature(''one_customer'', true) and __Q__.cust_has_money(p_id) then null; else\n  begin\n    delete from __P__.customers where id = p_id;');
    n := replace(n, E'  exception when foreign_key_violation then null;\n  end;\n', E'  exception when foreign_key_violation then null;\n  end;\n  end if;\n');
    if position('cust_has_money' in n) = 0 or position(E'end if;\n  foreach' in n) = 0 then raise notice 'one_customer: customer_remove is different, skipped';
    else execute n; end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'one_customer:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
