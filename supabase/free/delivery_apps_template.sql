delete from mf.template where name like 'delivery_apps:%';
insert into mf.template (ord, phase, kind, name, sql) values (302601, 3, 'patch', 'delivery_apps:302601', $TPL$alter table __P__.shop_orders add column if not exists delivery_app text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302602, 3, 'patch', 'delivery_apps:302602', $TPL$alter table __P__.shop_orders add column if not exists delivery_ref text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302603, 3, 'patch', 'delivery_apps:302603', $TPL$alter table __P__.shop_orders add column if not exists delivery_fee_thb integer;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302604, 3, 'patch', 'delivery_apps:302604', $TPL$alter table __P__.shop_orders add column if not exists delivery_payout_thb integer;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302605, 3, 'patch', 'delivery_apps:302605', $TPL$alter table __P__.shop_orders add column if not exists delivery_matched_at timestamptz;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001301, 10, 'patch', 'delivery_apps:1001301', $TPL$create index if not exists shop_orders_delivery on __P__.shop_orders (delivery_app, paid_at) where method = 'delivery';$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001302, 10, 'patch', 'delivery_apps:1001302', $TPL$do $p$
declare d text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = '__P__.shop_orders'::regclass and conname = 'shop_orders_method_check';
  if d is null or position('''delivery''' in d) > 0 then return; end if;
  alter table __P__.shop_orders drop constraint shop_orders_method_check;
  alter table __P__.shop_orders add constraint shop_orders_method_check check (method = any (array['cash','qr','card','transfer','room','stripe','staff','delivery']));
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402701, 4, 'patch', 'delivery_apps:402701', $TPL$create or replace function __Q__.delivery_apps() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce((select case when jsonb_typeof(v->'delivery_apps') = 'array' then v->'delivery_apps' end
    from (select (s.value)::jsonb v from __P__.app_settings s where s.key = 'pay_extras') x), '[]'::jsonb)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402702, 4, 'patch', 'delivery_apps:402702', $TPL$create or replace function __Q__.dref(t text) returns text language sql immutable as $f$
  select nullif(upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')), '')
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402703, 4, 'patch', 'delivery_apps:402703', $TPL$create or replace function __P__.shop_delivery_sell(p jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare a jsonb; nm text := btrim(coalesce(p->>'app', '')); ref text := left(btrim(coalesce(p->>'ref', '')), 60); tot int; pct numeric; r jsonb; fee int;
begin
  if not __Q__.feature('delivery_apps', false) then raise exception 'Switched off in Settings, Features.'; end if;
  if not __Q__.shop_till() then raise exception 'Only the front desk and managers can use the till.'; end if;
  select x into a from jsonb_array_elements(__Q__.delivery_apps()) x where lower(x->>'name') = lower(nm) limit 1;
  if a is null then raise exception 'Add % in Settings, Money, Delivery apps first.', coalesce(nullif(nm, ''), 'the app'); end if;
  if __Q__.dref(ref) is null then raise exception 'Type the order number from the % order.', a->>'name'; end if;
  begin tot := round((p->>'total')::numeric); exception when others then tot := null; end;
  if tot is null or tot <= 0 or tot > 1000000 then raise exception 'Type the order total that % shows.', a->>'name'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) i where i ? 'package') then raise exception 'Packages cannot be sold through a delivery app.'; end if;
  if exists (select 1 from __P__.shop_orders o where o.method = 'delivery' and lower(o.delivery_app) = lower(a->>'name') and __Q__.dref(o.delivery_ref) = __Q__.dref(ref)
      and o.status = 'paid' and o.paid_at > now() - interval '3 days') then
    raise exception '% order % is already on the till.', a->>'name', ref; end if;
  -- the normal sale (items, stock, kitchen), then it becomes a delivery app sale
  r := __P__.shop_sell(jsonb_build_object('location_id', p->'location_id', 'method', 'transfer', 'items', p->'items', 'note', p->'note'));
  pct := least(greatest(coalesce((a->>'pct')::numeric, 0), 0), 100);
  fee := round(tot * pct / 100);
  update __P__.shop_orders set method = 'delivery', delivery_app = a->>'name', delivery_ref = ref, total_thb = tot, discount_thb = 0, fee_thb = 0, tax_thb = 0,
      delivery_fee_thb = fee, deliver_to = left(a->>'name' || ' ' || ref, 120)
    where id = (r->>'id')::uuid;
  return jsonb_build_object('id', r->'id', 'number', r->'number', 'total', tot, 'fee', fee, 'app', a->>'name');
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196701, 11, 'patch', 'delivery_apps:1196701', $TPL$revoke all on function __P__.shop_delivery_sell(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196702, 11, 'patch', 'delivery_apps:1196702', $TPL$grant execute on function __P__.shop_delivery_sell(jsonb) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402704, 4, 'patch', 'delivery_apps:402704', $TPL$create or replace function __P__.shop_delivery_match(p_app text, p_rows jsonb, p_save boolean) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare r jsonb; i int := 0; oid uuid; d date; g numeric; fe numeric; nt numeric; dmin date; dmax date;
  used uuid[] := '{}'; matched jsonb := '[]'::jsonb; missing jsonb := '[]'::jsonb; extra jsonb; nm text;
begin
  if not __Q__.feature('delivery_apps', false) then raise exception 'Switched off in Settings, Features.'; end if;
  if coalesce(__Q__.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can do this.'; end if;
  select x->>'name' into nm from jsonb_array_elements(__Q__.delivery_apps()) x where lower(x->>'name') = lower(btrim(coalesce(p_app, ''))) limit 1;
  if nm is null then raise exception 'Choose the delivery app.'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No orders found in the file.'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'The file has too many lines. Upload one month at a time.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin d := (r->>'day')::date; exception when others then d := null; end;
    begin g := round((r->>'gross')::numeric); exception when others then g := null; end;
    begin fe := round(abs((r->>'fee')::numeric)); exception when others then fe := null; end;
    begin nt := round((r->>'net')::numeric); exception when others then nt := null; end;
    if fe is null and g is not null and nt is not null then fe := g - nt; end if;
    if d is not null then dmin := least(coalesce(dmin, d), d); dmax := greatest(coalesce(dmax, d), d); end if;
    oid := null;
    if __Q__.dref(r->>'ref') is not null then
      select o.id into oid from __P__.shop_orders o where o.method = 'delivery' and o.status = 'paid' and lower(o.delivery_app) = lower(nm) and not (o.id = any (used))
        and (__Q__.dref(o.delivery_ref) = __Q__.dref(r->>'ref') or (length(__Q__.dref(o.delivery_ref)) >= 4 and __Q__.dref(r->>'ref') like '%' || __Q__.dref(o.delivery_ref)))
        and (d is null or (o.paid_at at time zone 'Asia/Bangkok')::date between d - 2 and d + 2)
      order by o.paid_at limit 1;
    end if;
    if oid is null and d is not null and g is not null then
      select o.id into oid from __P__.shop_orders o where o.method = 'delivery' and o.status = 'paid' and lower(o.delivery_app) = lower(nm) and not (o.id = any (used))
        and o.delivery_matched_at is null and (o.paid_at at time zone 'Asia/Bangkok')::date between d - 1 and d + 1 and o.total_thb = g
      order by o.paid_at limit 1;
    end if;
    if oid is null then
      missing := missing || jsonb_build_object('line', i, 'ref', r->>'ref', 'day', d, 'gross', g, 'fee', fe, 'net', nt);
      continue;
    end if;
    used := used || oid;
    matched := matched || (select jsonb_build_object('id', o.id, 'number', o.number, 'ref', o.delivery_ref, 'day', (o.paid_at at time zone 'Asia/Bangkok')::date,
        'till_total', o.total_thb, 'gross', g, 'fee_before', o.delivery_fee_thb, 'fee', fe, 'net', nt) from __P__.shop_orders o where o.id = oid);
    if p_save then
      update __P__.shop_orders set total_thb = coalesce(g::int, total_thb), delivery_fee_thb = coalesce(fe::int, delivery_fee_thb),
        delivery_payout_thb = coalesce(nt::int, case when g is not null and fe is not null then (g - fe)::int end, delivery_payout_thb), delivery_matched_at = now()
      where id = oid;
    end if;
  end loop;
  -- till orders in the statement's dates that the statement does not have
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'number', o.number, 'ref', o.delivery_ref, 'day', (o.paid_at at time zone 'Asia/Bangkok')::date, 'total', o.total_thb) order by o.paid_at), '[]'::jsonb)
    into extra from __P__.shop_orders o
    where o.method = 'delivery' and o.status = 'paid' and lower(o.delivery_app) = lower(nm) and not (o.id = any (used)) and o.delivery_matched_at is null
      and dmin is not null and (o.paid_at at time zone 'Asia/Bangkok')::date between dmin and dmax;
  return jsonb_build_object('app', nm, 'from', dmin, 'to', dmax, 'matched', matched, 'not_on_till', missing, 'not_on_statement', extra, 'saved', coalesce(p_save, false));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196703, 11, 'patch', 'delivery_apps:1196703', $TPL$revoke all on function __P__.shop_delivery_match(text, jsonb, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196704, 11, 'patch', 'delivery_apps:1196704', $TPL$grant execute on function __P__.shop_delivery_match(text, jsonb, boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001303, 10, 'patch', 'delivery_apps:1001303', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__Q__.acc_lines(date, date)') is null then raise notice 'no accounts here, skipped'; return; end if;
  d := pg_get_functiondef('__Q__.acc_lines(date, date)'::regprocedure);
  if position('delivery_fee' in d) > 0 then raise notice 'acc_lines already has delivery app fees'; return; end if;
  n := regexp_replace(d, '\s*\$function\$\s*$', $x$
  union all
  -- delivery apps: their commission on each order
  select (o.paid_at at time zone 'Asia/Bangkok')::date, coalesce(l.acc_business, case when lower(coalesce(l.name,'')) like '%cafe%' then __Q__.biz_cafe() else __Q__.biz_main() end),
    coalesce(l.acc_department, case when lower(coalesce(l.name,'')) like '%cafe%' then __Q__.dept_cafe() else 'Gym shop' end),
    'out', coalesce(o.delivery_app, 'Delivery app') || ' commission: sale #' || o.number, 'Delivery app fees', 'delivery', o.delivery_fee_thb::numeric, 'delivery_fee', o.id, null
  from __P__.shop_orders o left join __P__.shop_locations l on l.id = o.location_id
  where o.status = 'paid' and o.method = 'delivery' and coalesce(o.delivery_fee_thb, 0) > 0 and o.paid_at is not null
    and (o.paid_at at time zone 'Asia/Bangkok')::date between p_from and p_to
$function$
$x$);
  if n = d then raise notice 'acc_lines: older version, skipped'; return; end if;
  execute n;
  if position('delivery_fee' in pg_get_functiondef('__Q__.acc_lines(date, date)'::regprocedure)) = 0 then raise exception 'acc_lines patch did not apply'; end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'delivery_apps:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
