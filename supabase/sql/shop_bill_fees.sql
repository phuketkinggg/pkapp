-- Shop till: "Bill to customer" (pay later, after class) and a card fee or tax added at payment.
-- A bill is an order waiting for payment with the customer on it. It is paid later from Shop, Waiting for payment.
-- fee_thb and tax_thb are on top of the items; Accounts shows them as Card fees charged and Tax collected.

alter table public.shop_orders add column if not exists fee_thb integer not null default 0;
alter table public.shop_orders add column if not exists tax_thb integer not null default 0;
alter table public.shop_orders add column if not exists billed boolean not null default false;

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.shop_sell(jsonb)'::regprocedure);
  if position('fee_thb' in d) > 0 then return; end if;
  n := d;
  n := replace(n, 'loc uuid := nullif(p->>''location_id'','''')::uuid; stf public.staff%rowtype; mn text; mp numeric;',
                  'loc uuid := nullif(p->>''location_id'','''')::uuid; stf public.staff%rowtype; mn text; mp numeric;
  fee int := greatest(coalesce(round(nullif(p->>''fee'','''')::numeric)::int, 0), 0); tx int := greatest(coalesce(round(nullif(p->>''tax'','''')::numeric)::int, 0), 0);');
  n := replace(n, 'if m not in (''cash'',''qr'',''card'',''transfer'',''room'',''stripe'',''staff'') then', 'if m not in (''cash'',''qr'',''card'',''transfer'',''room'',''stripe'',''staff'',''bill'') then');
  n := replace(n, '  if m = ''staff'' then
    select * into stf', '  if m = ''bill'' and oid is not null then raise exception ''That order is already waiting for payment.''; end if;
  if m = ''bill'' and cust is null then raise exception ''Choose the customer to put the bill on.''; end if;
  if m = ''staff'' then
    select * into stf');
  n := replace(n, '    sub := o.subtotal_thb;', '    sub := o.subtotal_thb; disc := coalesce(o.discount_thb, 0);');
  n := replace(n, 'if disc > 0 then appr := private.shop_approver(', 'if disc > 0 and oid is null then appr := private.shop_approver(');
  n := replace(n, '  tot := sub - disc;', '  tot := sub - disc + fee + tx;');
  n := replace(n, 'update public.shop_orders set status = case when m = ''room'' then ''room'' when m = ''stripe'' then ''waiting'' else ''paid'' end, method = case when m = ''stripe'' then null else m end,',
                  'update public.shop_orders set status = case when m = ''room'' then ''room'' when m in (''stripe'',''bill'') then ''waiting'' else ''paid'' end, method = case when m in (''stripe'',''bill'') then null else m end,
    fee_thb = fee, tax_thb = tx, billed = billed or m = ''bill'',');
  n := replace(n, 'discount_reason = nullif(btrim(p->>''discount_reason''),''''), approved_by = appr,', 'discount_reason = coalesce(nullif(btrim(p->>''discount_reason''),''''), discount_reason), approved_by = coalesce(appr, approved_by),');
  n := replace(n, 'paid_at = case when m = ''stripe'' then null else now() end,', 'paid_at = case when m in (''stripe'',''bill'') then null else now() end,');
  if position('fee_thb = fee' in n) = 0 or position('tot := sub - disc + fee + tx' in n) = 0 or position('disc := coalesce(o.discount_thb, 0)' in n) = 0
     or position('''bill'') then' in n) = 0 or position('coalesce(appr, approved_by)' in n) = 0 or position('m in (''stripe'',''bill'') then null else now()' in n) = 0 then
    raise exception 'shop_sell not changed';
  end if;
  execute n;

  -- the till's lists: fee, tax and the customer on bills
  d := pg_get_functiondef('public.shop_sales(date,date)'::regprocedure);
  if position('''fee''' in d) = 0 then
    n := replace(d, '''subtotal'', o.subtotal_thb, ''discount'', o.discount_thb, ''total'', o.total_thb,', '''subtotal'', o.subtotal_thb, ''discount'', o.discount_thb, ''fee'', o.fee_thb, ''tax'', o.tax_thb, ''billed'', o.billed, ''total'', o.total_thb,');
    n := replace(n, '''waiting'', (select coalesce(jsonb_agg(jsonb_build_object(''id'', o.id, ''location_id'', o.location_id, ''number'', o.number, ''at'', o.created_at, ''total'', o.total_thb,',
                    '''waiting'', (select coalesce(jsonb_agg(jsonb_build_object(''id'', o.id, ''location_id'', o.location_id, ''number'', o.number, ''at'', o.created_at, ''total'', o.total_thb, ''subtotal'', o.subtotal_thb, ''discount'', o.discount_thb, ''fee'', o.fee_thb, ''tax'', o.tax_thb, ''billed'', o.billed, ''customer_id'', o.customer_id,');
    if position('''customer_id'', o.customer_id' in n) = 0 or position('''fee'', o.fee_thb, ''tax'', o.tax_thb, ''billed'', o.billed, ''total''' in n) = 0 then raise exception 'shop_sales not changed'; end if;
    execute n;
  end if;

  -- Accounts: items without the fee and tax, then the fee and tax as their own lines
  d := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  if position('o.fee_thb' in d) = 0 then
    n := replace(d, 'case when o.subtotal_thb > 0 then o.total_thb::numeric / o.subtotal_thb else 1 end', 'case when o.subtotal_thb > 0 then (o.total_thb - o.fee_thb - o.tax_thb)::numeric / o.subtotal_thb else 1 end');
    n := replace(n, '  union all
  -- receipts (with an amount)', '  union all
  -- card fee and tax charged on till sales
  select (o.paid_at at time zone ''Asia/Bangkok'')::date,
    case when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Resort'' else ''Phuket King Gym'' end,
    case when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Cafe'' else ''Gym shop'' end,
    ''in'', x.w || ''sale #'' || o.number, x.c, o.method, x.a::numeric, ''shop'', o.id, null
  from public.shop_orders o left join public.shop_locations l on l.id = o.location_id
    cross join lateral (values (''Card fee: '', ''Card fees charged'', o.fee_thb), (''Tax: '', ''Tax collected'', o.tax_thb)) x(w, c, a)
  where o.status = ''paid'' and o.paid_at is not null and (o.paid_at at time zone ''Asia/Bangkok'')::date between p_from and p_to and x.a > 0
  union all
  -- receipts (with an amount)');
    if position('Card fee: ''' in n) = 0 or position('(o.total_thb - o.fee_thb - o.tax_thb)' in n) = 0 then raise exception 'acc_lines not changed'; end if;
    execute n;
  end if;
end $$;

-- a card fee or tax on an order that is waiting for a card link payment
create or replace function public.shop_order_extras(p_order uuid, p_fee integer, p_tax integer) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare o public.shop_orders;
begin
  if not private.shop_till() then raise exception 'Only the front desk and managers can use the till.'; end if;
  update public.shop_orders set fee_thb = greatest(coalesce(p_fee,0),0), tax_thb = greatest(coalesce(p_tax,0),0),
    total_thb = subtotal_thb - discount_thb + greatest(coalesce(p_fee,0),0) + greatest(coalesce(p_tax,0),0)
  where id = p_order and status = 'waiting' returning * into o;
  if o.id is null then raise exception 'That order is already paid.'; end if;
  return jsonb_build_object('id', o.id, 'number', o.number, 'total', o.total_thb);
end $f$;
grant execute on function public.shop_order_extras(uuid, integer, integer) to authenticated;
