delete from mf.template where name like 'shop_tabs:%';
insert into mf.template (ord, phase, kind, name, sql) values (302001, 3, 'patch', 'shop_tabs:302001', $TPL$alter table __P__.shop_orders add column if not exists tab_name text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302002, 3, 'patch', 'shop_tabs:302002', $TPL$alter table __P__.shop_orders add column if not exists kdone_round integer;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302003, 3, 'patch', 'shop_tabs:302003', $TPL$alter table __P__.shop_order_items add column if not exists kround integer;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302004, 3, 'patch', 'shop_tabs:302004', $TPL$alter table __P__.shop_order_items add column if not exists added_at timestamptz default now();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000401, 10, 'patch', 'shop_tabs:1000401', $TPL$create index if not exists shop_orders_tabs on __P__.shop_orders (location_id) where status = 'waiting' and tab_name is not null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402001, 4, 'patch', 'shop_tabs:402001', $TPL$create or replace function __Q__.shop_kdone() returns trigger language plpgsql security definer set search_path to '' as $f$
begin
  if new.kitchen_status = 'done' and old.kitchen_status is distinct from 'done' then
    new.kdone_round := coalesce((select max(i.kround) from __P__.shop_order_items i where i.order_id = new.id), 0);
  end if;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900601, 9, 'patch', 'shop_tabs:900601', $TPL$drop trigger if exists shop_orders_kdone on __P__.shop_orders;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900602, 9, 'patch', 'shop_tabs:900602', $TPL$create trigger shop_orders_kdone before update of kitchen_status on __P__.shop_orders for each row execute function __Q__.shop_kdone();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402002, 4, 'patch', 'shop_tabs:402002', $TPL$create or replace function __P__.shop_tab_add(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare me_s uuid := __Q__.my_staff_id(); oid uuid := nullif(p->>'order_id','')::uuid; o __P__.shop_orders%rowtype; loc uuid := nullif(p->>'location_id','')::uuid;
  shift uuid; nm text := left(btrim(coalesce(p->>'name','')), 40); it jsonb; pr __P__.shop_products%rowtype; qty int; mn text; mp numeric; md jsonb;
  anyk boolean := false; rnd int; sub int; added int := 0; disc int := greatest(coalesce(nullif(p->>'discount','')::numeric::int, 0), 0); appr uuid;
begin
  if not __Q__.shop_till() then raise exception 'Only the front desk and managers can use the till.'; end if;
  if not __Q__.feature('shop_tabs', true) then raise exception 'Tabs are switched off in Settings, Features.'; end if;
  if coalesce(jsonb_typeof(p->'items'), '') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'Add something first.'; end if;
  if oid is not null then
    select * into o from __P__.shop_orders where id = oid for update;
    if o.id is null or o.status <> 'waiting' or o.tab_name is null then raise exception 'That tab is already paid or closed.'; end if;
    loc := o.location_id;
  else
    if loc is null then raise exception 'Choose which shop this till is. Reload the app.'; end if;
    if nm = '' then raise exception 'Give the tab a name, for example Table 1.'; end if;
    if exists (select 1 from __P__.shop_orders x where x.status = 'waiting' and x.location_id = loc and lower(x.tab_name) = lower(nm)) then
      raise exception '% already has an open tab. Tap it to add more.', nm; end if;
  end if;
  select id into shift from __P__.shop_shifts where location_id = loc and closed_at is null;
  if shift is null then raise exception 'Open a shift first, with the cash in the till.'; end if;
  if o.id is null then
    insert into __P__.shop_orders (created_by, source, customer_id, status, subtotal_thb, total_thb, shift_id, location_id, tab_name, billed)
      values (me_s, 'till', nullif(p->>'customer_id','')::uuid, 'waiting', 0, 0, shift, loc, nm, false) returning * into o;
  end if;
  rnd := coalesce((select max(i.kround) from __P__.shop_order_items i where i.order_id = o.id), 0) + 1;
  for it in select * from jsonb_array_elements(p->'items') loop
    if it ? 'package' then raise exception 'Training packages cannot go on a tab. Sell them on their own.'; end if;
    qty := greatest(coalesce((it->>'qty')::int, 1), 1);
    if coalesce((it->>'misc')::boolean, false) then
      mn := left(btrim(coalesce(it->>'name','')), 120);
      if mn = '' then raise exception 'Type what the other item is.'; end if;
      begin mp := round((it->>'price')::numeric); exception when others then mp := null; end;
      if mp is null or mp < 0 or mp > 1000000 then raise exception 'Type the price for %.', mn; end if;
      insert into __P__.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen, added_at) values (o.id, null, mn, mp::int, qty, nullif(btrim(it->>'note'),''), false, now());
      added := added + mp::int * qty;
      continue;
    end if;
    select * into pr from __P__.shop_products where id = (it->>'product_id')::uuid and active;
    if pr.id is null then raise exception 'A product on the order is not on the menu any more.'; end if;
    if pr.open_price then
      if nullif(it->>'price','') is null or (it->>'price')::numeric < 0 then raise exception 'Type the price for %.', pr.name; end if;
      pr.price_thb := round((it->>'price')::numeric);
    end if;
    md := __Q__.shop_mods(pr.id, it->'mods'); pr.price_thb := pr.price_thb + coalesce((md->>'extra')::int, 0);
    insert into __P__.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen, mods, kround, added_at)
      values (o.id, pr.id, left(pr.name || coalesce(' (' || nullif(md->>'label', '') || ')', ''), 200), pr.price_thb, qty, nullif(btrim(it->>'note'),''), pr.kitchen, md->'list',
              case when pr.kitchen then rnd end, now());
    if pr.track_stock then perform __Q__.shop_stock_move(pr.id, loc, -qty, 'sale', o.id); end if;
    anyk := anyk or pr.kitchen; added := added + pr.price_thb * qty;
  end loop;
  if disc > added then raise exception 'The discount is more than what is being added.'; end if;
  if disc > 0 then
    appr := __Q__.shop_approver('discount', disc, p->>'pin', nullif(p->>'approval_id','')::uuid, o.id);
    update __P__.shop_orders set discount_thb = coalesce(discount_thb, 0) + disc, approved_by = coalesce(appr, approved_by),
      discount_reason = left(concat_ws('; ', discount_reason, nullif(btrim(coalesce(p->>'discount_reason','')), '')), 300) where id = o.id returning * into o;
  end if;
  select coalesce(sum(i.price_thb * i.qty), 0) into sub from __P__.shop_order_items i where i.order_id = o.id and not i.removed;
  update __P__.shop_orders set subtotal_thb = sub, total_thb = greatest(sub - coalesce(discount_thb, 0), 0) + coalesce(fee_thb, 0) + coalesce(tax_thb, 0),
    kitchen_status = case when anyk then 'new' else kitchen_status end where id = o.id returning * into o;
  return jsonb_build_object('id', o.id, 'number', o.number, 'name', o.tab_name, 'total', o.total_thb, 'kitchen', anyk);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196001, 11, 'patch', 'shop_tabs:1196001', $TPL$revoke all on function __P__.shop_tab_add(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196002, 11, 'patch', 'shop_tabs:1196002', $TPL$grant execute on function __P__.shop_tab_add(jsonb) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402003, 4, 'patch', 'shop_tabs:402003', $TPL$create or replace function __P__.shop_tab_remove(p_item uuid) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare it __P__.shop_order_items%rowtype; o __P__.shop_orders%rowtype; sub int;
begin
  if not __Q__.shop_till() then raise exception 'Not allowed.'; end if;
  select * into it from __P__.shop_order_items where id = p_item and not removed;
  if it.id is null then raise exception 'That line is not on the tab.'; end if;
  select * into o from __P__.shop_orders where id = it.order_id for update;
  if o.status <> 'waiting' or o.tab_name is null then raise exception 'That tab is already paid or closed.'; end if;
  if coalesce(it.added_at, o.created_at) < now() - interval '10 minutes'
     or (it.kitchen and not (o.kitchen_status = 'new' and coalesce(it.kround, 0) > coalesce(o.kdone_round, 0))) then
    raise exception 'A manager has to remove this one with their PIN (it was added a while ago, or the kitchen has started it).';
  end if;
  if it.product_id is not null and exists (select 1 from __P__.shop_products x where x.id = it.product_id and x.track_stock) then
    perform __Q__.shop_stock_move(it.product_id, o.location_id, it.qty, 'mistake', o.id); end if;
  update __P__.shop_order_items set removed = true where id = it.id;
  select coalesce(sum(i.price_thb * i.qty), 0) into sub from __P__.shop_order_items i where i.order_id = o.id and not i.removed;
  if not exists (select 1 from __P__.shop_order_items i where i.order_id = o.id and not i.removed) then
    update __P__.shop_orders set status = 'void', subtotal_thb = 0, total_thb = 0, refunded_at = now(), refund_reason = 'Tab emptied',
      kitchen_status = case when kitchen_status in ('new','preparing','ready') then 'done' else kitchen_status end where id = o.id;
    return jsonb_build_object('closed', true);
  end if;
  if it.kitchen and not exists (select 1 from __P__.shop_order_items i where i.order_id = o.id and not i.removed and i.kitchen and coalesce(i.kround, 0) > coalesce(o.kdone_round, 0)) then
    update __P__.shop_orders set kitchen_status = 'done' where id = o.id;
  end if;
  update __P__.shop_orders set subtotal_thb = sub, discount_thb = least(coalesce(discount_thb, 0), sub),
    total_thb = greatest(sub - least(coalesce(discount_thb, 0), sub), 0) + coalesce(fee_thb, 0) + coalesce(tax_thb, 0) where id = o.id returning * into o;
  return jsonb_build_object('closed', false, 'total', o.total_thb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196003, 11, 'patch', 'shop_tabs:1196003', $TPL$revoke all on function __P__.shop_tab_remove(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196004, 11, 'patch', 'shop_tabs:1196004', $TPL$grant execute on function __P__.shop_tab_remove(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402004, 4, 'patch', 'shop_tabs:402004', $TPL$create or replace function __P__.shop_tab_rename(p_order uuid, p_name text) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare o __P__.shop_orders%rowtype; nm text := left(btrim(coalesce(p_name,'')), 40);
begin
  if not __Q__.shop_till() then raise exception 'Not allowed.'; end if;
  if nm = '' then raise exception 'Give the tab a name, for example Table 1.'; end if;
  select * into o from __P__.shop_orders where id = p_order for update;
  if o.id is null or o.status <> 'waiting' or o.tab_name is null then raise exception 'That tab is already paid or closed.'; end if;
  if exists (select 1 from __P__.shop_orders x where x.id <> o.id and x.status = 'waiting' and x.location_id = o.location_id and lower(x.tab_name) = lower(nm)) then
    raise exception '% already has an open tab.', nm; end if;
  update __P__.shop_orders set tab_name = nm where id = o.id;
  return jsonb_build_object('id', o.id, 'name', nm);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196005, 11, 'patch', 'shop_tabs:1196005', $TPL$revoke all on function __P__.shop_tab_rename(uuid, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196006, 11, 'patch', 'shop_tabs:1196006', $TPL$grant execute on function __P__.shop_tab_rename(uuid, text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000402, 10, 'patch', 'shop_tabs:1000402', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.shop_sales(date,date)') is null then raise notice 'no shop_sales here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.shop_sales(date,date)'::regprocedure);
  if position('tab_name' in d) > 0 then raise notice 'shop_sales already patched'; return; end if;
  n := replace(d, $x$'deliver_to', o.deliver_to, 'note', o.note,$x$, $x$'deliver_to', o.deliver_to, 'note', o.note, 'tab', o.tab_name,$x$);
  n := replace(n, $x$jsonb_build_object('name', i.name, 'qty', i.qty)), '[]'::jsonb)$x$,
    $x$jsonb_build_object('id', i.id, 'name', i.name, 'qty', i.qty, 'price', i.price_thb, 'note', i.note, 'kitchen', i.kitchen, 'at', i.added_at) order by i.added_at nulls first), '[]'::jsonb)$x$);
  n := replace(n, $x$'kitchen_status', o.kitchen_status,$x$, $x$'kitchen_status', o.kitchen_status, 'tab', o.tab_name,$x$);
  if n = d then raise notice 'shop_sales: older version, skipped'; return; end if;
  execute n;
  if position('tab_name' in pg_get_functiondef('__P__.shop_sales(date,date)'::regprocedure)) = 0 then raise exception 'shop_sales patch did not apply'; end if;
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000403, 10, 'patch', 'shop_tabs:1000403', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.shop_kitchen()') is null then raise notice 'no shop_kitchen here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.shop_kitchen()'::regprocedure);
  if position('kdone_round' in d) > 0 then raise notice 'shop_kitchen already patched'; return; end if;
  n := replace(d, $x$'id', o.id, 'number', o.number, 'at', o.created_at,$x$,
    $x$'id', o.id, 'number', o.number, 'tab', o.tab_name,
      'at', coalesce((select min(i.added_at) from __P__.shop_order_items i where i.order_id = o.id and not i.removed and i.kitchen and coalesce(i.kround, 0) > coalesce(o.kdone_round, 0)), o.created_at),$x$);
  n := replace(n, $x$'deliver_to', o.deliver_to,$x$, $x$'deliver_to', coalesce(o.deliver_to, o.tab_name),$x$);
  n := replace(n, $x$jsonb_build_object('name', i.name, 'qty', i.qty, 'note', i.note) order by i.name), '[]'::jsonb) from __P__.shop_order_items i where i.order_id = o.id and not i.removed and i.kitchen)$x$,
    $x$jsonb_build_object('name', i.name, 'qty', i.qty, 'note', i.note, 'added', coalesce(i.kround, 0) > 1) order by i.kround nulls first, i.name), '[]'::jsonb) from __P__.shop_order_items i where i.order_id = o.id and not i.removed and i.kitchen and coalesce(i.kround, 0) > coalesce(o.kdone_round, 0))$x$);
  n := replace(n, $x$o.created_at > now() - interval '24 hours'$x$, $x$(o.created_at > now() - interval '24 hours' or o.tab_name is not null)$x$);
  if n = d then raise notice 'shop_kitchen: older version, skipped'; return; end if;
  execute n;
  if position('kdone_round' in pg_get_functiondef('__P__.shop_kitchen()'::regprocedure)) = 0 then raise exception 'shop_kitchen patch did not apply'; end if;
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402005, 4, 'patch', 'shop_tabs:402005', $TPL$create or replace function __P__.shop_product_delete(p_id uuid) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare nm text;
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can delete products.'; end if;
  select name into nm from __P__.shop_products where id = p_id;
  if nm is null then raise exception 'That product was not found.'; end if;
  begin
    delete from __P__.shop_products where id = p_id;
    return jsonb_build_object('deleted', true, 'name', nm);
  exception when foreign_key_violation then
    update __P__.shop_products set active = false, in_app = false, on_web = false where id = p_id;
    return jsonb_build_object('deleted', false, 'name', nm, 'note', 'It is still used somewhere, so it was taken off sale instead.');
  end;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196007, 11, 'patch', 'shop_tabs:1196007', $TPL$revoke all on function __P__.shop_product_delete(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196008, 11, 'patch', 'shop_tabs:1196008', $TPL$grant execute on function __P__.shop_product_delete(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402006, 4, 'patch', 'shop_tabs:402006', $TPL$create or replace function __P__.shop_menu_build(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare cid uuid; cname text := btrim(coalesce(p->'category'->>'name', p->>'category', '')); m jsonb; o jsonb; opts jsonb; om __P__.shop_modifiers%rowtype; mid uuid;
  modmap jsonb := '{}'::jsonb; allmods uuid[] := '{}'; pr jsonb; pid uuid; ids uuid[]; nm text; made text[] := '{}'; changed text[] := '{}'; mods text[] := '{}';
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change the menu.'; end if;
  if cname <> '' then
    select id into cid from __P__.shop_categories where lower(name) = lower(cname) order by active desc limit 1;
    if cid is null then
      insert into __P__.shop_categories (name, sort, active) values (left(cname, 60), coalesce((select max(sort) + 1 from __P__.shop_categories), 0), true) returning id into cid;
    else update __P__.shop_categories set active = true where id = cid; end if;
  end if;
  for m in select * from jsonb_array_elements(case when jsonb_typeof(p->'modifiers') = 'array' then p->'modifiers' else '[]'::jsonb end) loop
    nm := btrim(coalesce(m->>'name','')); if nm = '' then continue; end if;
    select * into om from __P__.shop_modifiers where lower(name) = lower(nm) order by active desc limit 1;
    opts := '[]'::jsonb;
    for o in select * from jsonb_array_elements(case when jsonb_typeof(m->'options') = 'array' then m->'options' else '[]'::jsonb end) loop
      opts := opts || jsonb_build_object('id', (select x->>'id' from jsonb_array_elements(coalesce(om.options, '[]'::jsonb)) x where lower(x->>'name') = lower(btrim(coalesce(o->>'name',''))) limit 1),
        'name', o->>'name', 'price', coalesce(nullif(o->>'price',''), '0'));
    end loop;
    mid := __P__.shop_modifier_save(jsonb_build_object('id', om.id, 'name', nm, 'required', coalesce((m->>'required')::boolean, false), 'multi', coalesce((m->>'multi')::boolean, false), 'options', opts));
    modmap := modmap || jsonb_build_object(lower(nm), mid); allmods := allmods || mid; mods := mods || nm;
    om := null;
  end loop;
  for pr in select * from jsonb_array_elements(case when jsonb_typeof(p->'products') = 'array' then p->'products' else '[]'::jsonb end) loop
    nm := left(btrim(coalesce(pr->>'name','')), 120); if nm = '' then continue; end if;
    if nullif(pr->>'price','') is null or (pr->>'price')::numeric < 0 then raise exception 'Give % a price.', nm; end if;
    if jsonb_typeof(pr->'modifiers') = 'array' then
      select coalesce(array_agg(z), '{}') into ids from (select coalesce((modmap->>lower(btrim(x)))::uuid,
        (select s.id from __P__.shop_modifiers s where lower(s.name) = lower(btrim(x)) and s.active limit 1)) z from jsonb_array_elements_text(pr->'modifiers') x) q where z is not null;
    else ids := allmods; end if;
    select id into pid from __P__.shop_products where lower(name) = lower(nm) and (cid is null or category_id = cid) order by active desc limit 1;
    if pid is null then
      insert into __P__.shop_products (name, category_id, price_thb, kitchen, in_app, active, sort, description, grp, modifier_ids)
        values (nm, cid, round((pr->>'price')::numeric), coalesce((pr->>'kitchen')::boolean, false), coalesce((pr->>'in_app')::boolean, false), true,
                coalesce((select max(sort) + 1 from __P__.shop_products where category_id is not distinct from cid), 0), nullif(btrim(coalesce(pr->>'description','')), ''),
                nullif(btrim(coalesce(pr->>'grp','')), ''), ids) returning id into pid;
      made := made || nm;
    else
      update __P__.shop_products set price_thb = round((pr->>'price')::numeric), active = true,
        kitchen = coalesce((pr->>'kitchen')::boolean, kitchen), in_app = coalesce((pr->>'in_app')::boolean, in_app),
        description = coalesce(nullif(btrim(coalesce(pr->>'description','')), ''), description), grp = case when pr ? 'grp' then nullif(btrim(coalesce(pr->>'grp','')), '') else grp end,
        modifier_ids = (select coalesce(array_agg(distinct x), '{}') from unnest(coalesce(modifier_ids, '{}') || ids) x) where id = pid;
      changed := changed || nm;
    end if;
    pid := null;
  end loop;
  return jsonb_build_object('category', nullif(cname, ''), 'new_products', to_jsonb(made), 'updated_products', to_jsonb(changed), 'modifiers', to_jsonb(mods));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196009, 11, 'patch', 'shop_tabs:1196009', $TPL$revoke all on function __P__.shop_menu_build(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196010, 11, 'patch', 'shop_tabs:1196010', $TPL$grant execute on function __P__.shop_menu_build(jsonb) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'shop_tabs:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
