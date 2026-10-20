-- Till sales put on a room bill now show in Accounts, as shop sales in their own department, on the day the bill is settled.
-- Before, settling only recorded what was still owed as one "Stay payment", so when a prepaid room covered the
-- till items (or the bill was settled with nothing to pay) they never showed in Money in.
-- Applies to bills settled from 20 Oct 2026; older settled bills already counted those items inside their stay payment.

-- voided charges never count towards what is owed
create or replace function private.stay_due(p_stay uuid) returns integer language sql stable security definer set search_path='' as $f$
  select (coalesce((select sum(amount_thb) from public.room_charges where stay_id = s.id and not coalesce(voided,false)),0) + coalesce(s.room_price_thb,0) - coalesce(s.room_paid_thb,0)
        - coalesce((select sum(amount_thb) from public.payments where stay_id = s.id and not voided),0))::int
  from public.stays s where s.id = p_stay
$f$;

-- till sales on the room bill
create or replace function private.stay_till_total(p_stay uuid) returns integer language sql stable security definer set search_path='' as $f$
  select coalesce(sum(amount_thb),0)::int from public.room_charges where stay_id = p_stay and order_id is not null and not coalesce(voided,false)
$f$;

-- settling: the stay payment is the room part only; the till part shows as shop sales (acc_lines below)
create or replace function private.stay_settled() returns trigger language plpgsql security definer set search_path='' as $f$
declare due integer;
begin
  if new.settled and not coalesce(old.settled,false) then
    due := private.stay_due(new.id) - private.stay_till_total(new.id);
    if due > 0 then perform private.pay_insert(new.customer_id, null, null, new.id, due, coalesce(new.settled_method,'cash'), coalesce(new.settled_on, private.bkk_today()), 'Room bill'); end if;
  elsif not new.settled and coalesce(old.settled,false) then
    update public.payments set voided = true where stay_id = new.id and not voided and stripe_session is null;
  end if;
  return null;
end $f$;

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  n := replace(d, '  union all
  -- receipts (with an amount)', '  union all
  -- till sales put on a room bill: counted when the bill is settled
  select s.settled_on,
    case when lower(coalesce(l.name,'''')) like ''%cafe%'' and lower(coalesce(c.name,'''')) <> ''spa'' then ''Pangea Resort'' else ''Phuket King Gym'' end,
    case when lower(coalesce(c.name,'''')) = ''spa'' then ''Spa'' when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Cafe'' else ''Gym shop'' end,
    ''in'', coalesce(c.name,''Shop'')||'': ''||i.name, ''Sales'', coalesce(s.settled_method,''room''),
    round(i.qty * i.price_thb * case when o.subtotal_thb > 0 then o.total_thb::numeric / o.subtotal_thb else 1 end, 2), ''shop'', o.id, null
  from public.shop_orders o join public.stays s on s.id = o.stay_id and s.settled and s.settled_on >= date ''2026-10-20''
    join public.shop_order_items i on i.order_id = o.id and not i.removed and i.purchase_id is null
    left join public.shop_products pr on pr.id = i.product_id left join public.shop_categories c on c.id = pr.category_id
    left join public.shop_locations l on l.id = o.location_id
  where o.status = ''room'' and s.settled_on between p_from and p_to
  union all
  -- receipts (with an amount)');
  if n = d then raise exception 'acc_lines not changed'; end if;
  execute n;
end $$;
