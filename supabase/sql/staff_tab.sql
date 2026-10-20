-- Staff tab: staff buy drinks, water or anything on the till and it goes on their tab, settled later (cash, transfer or from wages).
-- Also a "misc" line on the till: any name, any price.

alter table public.shop_orders add column if not exists staff_id uuid references public.staff(id) on delete set null;
alter table public.shop_orders drop constraint if exists shop_orders_method_check;
alter table public.shop_orders add constraint shop_orders_method_check check (method = any (array['cash','qr','card','transfer','room','stripe','staff']));

create table if not exists public.staff_charges(
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  day date not null default ((now() at time zone 'Asia/Bangkok')::date),
  description text not null check (char_length(description) between 1 and 200),
  amount_thb int not null check (amount_thb >= 0),
  order_id uuid references public.shop_orders(id) on delete set null,
  created_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now(),
  voided boolean not null default false,
  settled_at timestamptz, settled_by uuid references public.staff(id) on delete set null, settled_how text, settled_note text
);
alter table public.staff_charges enable row level security;
revoke all on public.staff_charges from anon, authenticated;
create index if not exists staff_charges_staff on public.staff_charges(staff_id, settled_at);

-- a till sale removed as a mistake (or refunded) comes off the tab too, unless it was already settled
create or replace function private.staff_charge_sync() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if new.method = 'staff' then
    update public.staff_charges set amount_thb = case when new.status in ('void','refunded') then 0 else new.total_thb end,
      voided = new.status in ('void','refunded')
    where order_id = new.id and settled_at is null;
  end if;
  return null;
end $f$;
drop trigger if exists shop_orders_staff_sync on public.shop_orders;
create trigger shop_orders_staff_sync after update on public.shop_orders for each row execute function private.staff_charge_sync();

create or replace function public.shop_sell(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $function$
declare me_s uuid := private.my_staff_id(); oid uuid := nullif(p->>'order_id','')::uuid; o public.shop_orders%rowtype;
  it jsonb; pr public.shop_products%rowtype; qty int; sub int := 0; disc int := greatest(coalesce((p->>'discount')::int, 0), 0); tot int;
  m text := p->>'method'; st public.stays%rowtype; cust uuid := nullif(p->>'customer_id','')::uuid; shift uuid; appr uuid; anyk boolean := false; descr text; given int;
  loc uuid := nullif(p->>'location_id','')::uuid; stf public.staff%rowtype; mn text; mp numeric;
begin
  if not private.shop_till() then raise exception 'Only the front desk and managers can use the till.'; end if;
  if m not in ('cash','qr','card','transfer','room','stripe','staff') then raise exception 'Choose how they pay.'; end if;
  if m = 'stripe' and oid is not null then raise exception 'Use the card link on the order itself.'; end if;
  if loc is null then raise exception 'Choose which shop this till is (Pangea Cafe or Muay Thai Gym). Reload the app.'; end if;
  select id into shift from public.shop_shifts where location_id = loc and closed_at is null;
  if shift is null then raise exception 'Open a shift first, with the cash in the till.'; end if;
  if m = 'room' then
    select * into st from public.stays where id = nullif(p->>'stay_id','')::uuid;
    if st.id is null or st.status <> 'in' or st.settled then raise exception 'Choose a guest who is staying now.'; end if;
    cust := coalesce(cust, st.customer_id);
  end if;
  if m = 'staff' then
    select * into stf from public.staff where id = nullif(p->>'staff_id','')::uuid and active;
    if stf.id is null then raise exception 'Choose who it is for.'; end if;
  end if;
  if oid is not null then
    select * into o from public.shop_orders where id = oid for update;
    if o.id is null or o.status <> 'waiting' then raise exception 'That order is already paid.'; end if;
    sub := o.subtotal_thb;
  else
    if jsonb_array_length(coalesce(p->'items','[]'::jsonb)) = 0 then raise exception 'Add something to the sale first.'; end if;
    insert into public.shop_orders (created_by, source, customer_id, status, subtotal_thb, total_thb, shift_id, note, location_id)
      values (me_s, 'till', cust, 'void', 0, 0, shift, nullif(btrim(p->>'note'),''), loc) returning * into o;
    for it in select * from jsonb_array_elements(p->'items') loop
      if it ? 'package' then
        if cust is null then raise exception 'Choose the customer for the training package.'; end if;
        if coalesce((select l.name from public.shop_locations l where l.id = loc),'') ilike '%cafe%' then raise exception 'Training packages are sold at the Muay Thai Gym till.'; end if;
        sub := sub + private.shop_package_line(o.id, cust, it);
        continue;
      end if;
      qty := greatest(coalesce((it->>'qty')::int, 1), 1);
      if coalesce((it->>'misc')::boolean, false) then
        mn := left(btrim(coalesce(it->>'name','')), 120);
        if mn = '' then raise exception 'Type what the other item is.'; end if;
        begin mp := round((it->>'price')::numeric); exception when others then mp := null; end;
        if mp is null or mp < 0 or mp > 1000000 then raise exception 'Type the price for %.', mn; end if;
        insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen) values (o.id, null, mn, mp::int, qty, nullif(btrim(it->>'note'),''), false);
        sub := sub + mp::int * qty;
        continue;
      end if;
      select * into pr from public.shop_products where id = (it->>'product_id')::uuid and active;
      if pr.id is null then raise exception 'A product in the sale is not on the menu any more.'; end if;
      if pr.open_price then
        if nullif(it->>'price','') is null or (it->>'price')::numeric < 0 then raise exception 'Type the price for %.', pr.name; end if;
        pr.price_thb := round((it->>'price')::numeric);
      end if;
      insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen) values (o.id, pr.id, pr.name, pr.price_thb, qty, nullif(btrim(it->>'note'),''), pr.kitchen);
      sub := sub + pr.price_thb * qty; anyk := anyk or pr.kitchen;
    end loop;
  end if;
  if disc > sub then raise exception 'The discount is more than the sale.'; end if;
  if disc > 0 then appr := private.shop_approver('discount', disc, p->>'pin', nullif(p->>'approval_id','')::uuid, null); end if;
  tot := sub - disc;
  given := case when m = 'cash' then nullif(p->>'cash_given','')::int end;
  if given is not null and given < tot then raise exception 'The cash given is less than the total.'; end if;
  update public.shop_orders set status = case when m = 'room' then 'room' when m = 'stripe' then 'waiting' else 'paid' end, method = case when m = 'stripe' then null else m end, subtotal_thb = sub, discount_thb = disc, total_thb = tot,
    discount_reason = nullif(btrim(p->>'discount_reason'),''), approved_by = appr, cash_given = given, paid_at = case when m = 'stripe' then null else now() end,
    customer_id = coalesce(cust, customer_id), stay_id = case when m = 'room' then st.id else stay_id end, staff_id = case when m = 'staff' then stf.id else staff_id end,
    shift_id = shift, created_by = coalesce(created_by, me_s), location_id = coalesce(location_id, loc),
    kitchen_status = case when oid is null and anyk then 'new' else kitchen_status end
  where id = o.id returning * into o;
  if oid is null then perform private.shop_order_stock(o.id, -1, 'sale'); end if;
  if m in ('room','staff') then
    select string_agg(i.qty || ' ' || i.name, ', ') into descr from public.shop_order_items i where i.order_id = o.id and not i.removed;
  end if;
  if m = 'room' then
    insert into public.room_charges (stay_id, day, description, amount_thb, kind, order_id, created_by)
      values (st.id, private.bkk_today(), left((select l.name from public.shop_locations l where l.id = loc) || ' #' || o.number || ': ' || coalesce(descr,''), 200), tot, 'cafe', o.id, me_s);
  end if;
  if m = 'staff' then
    insert into public.staff_charges (staff_id, day, description, amount_thb, order_id, created_by)
      values (stf.id, private.bkk_today(), left((select l.name from public.shop_locations l where l.id = loc) || ' #' || o.number || ': ' || coalesce(descr,''), 200), tot, o.id, me_s);
  end if;
  return jsonb_build_object('id', o.id, 'number', o.number, 'total', tot, 'change', case when given is not null then given - tot end, 'method', m);
end $function$;

-- managers (and the desk, to add a charge) work with the tabs
create or replace function public.staff_tabs() returns jsonb language plpgsql stable security definer set search_path='' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see staff tabs.'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'owed')::int desc, x->>'name') from (
    select jsonb_build_object('staff_id', s.id, 'name', s.name, 'role', s.role, 'active', s.active,
      'owed', coalesce((select sum(c.amount_thb) from public.staff_charges c where c.staff_id=s.id and c.settled_at is null and not c.voided),0),
      'charges', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'day', c.day, 'description', c.description, 'amount', c.amount_thb, 'till', c.order_id is not null,
          'voided', c.voided, 'settled_at', c.settled_at, 'settled_how', c.settled_how, 'by', (select b.name from public.staff b where b.id=c.created_by)) order by c.created_at desc)
        from public.staff_charges c where c.staff_id=s.id and (c.settled_at is null or c.settled_at > now() - interval '60 days')),'[]'::jsonb)) x
    from public.staff s
    where s.active or exists (select 1 from public.staff_charges c where c.staff_id=s.id and c.settled_at is null and not c.voided)) q), '[]'::jsonb);
end $f$;
revoke all on function public.staff_tabs() from public, anon;
grant execute on function public.staff_tabs() to authenticated;

create or replace function public.staff_charge_add(p_staff uuid, p_desc text, p_amount int) returns uuid language plpgsql security definer set search_path='' as $f$
declare v uuid;
begin
  if not private.shop_till() then raise exception 'Only the front desk and managers can add to a staff tab.'; end if;
  if not exists (select 1 from public.staff where id=p_staff and active) then raise exception 'Choose who it is for.'; end if;
  if btrim(coalesce(p_desc,'')) = '' then raise exception 'Say what it is for.'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'Type the amount.'; end if;
  insert into public.staff_charges(staff_id, description, amount_thb, created_by) values (p_staff, left(btrim(p_desc),200), p_amount, private.my_staff_id()) returning id into v;
  return v;
end $f$;
revoke all on function public.staff_charge_add(uuid, text, int) from public, anon;
grant execute on function public.staff_charge_add(uuid, text, int) to authenticated;

create or replace function public.staff_tab_settle(p_staff uuid, p_how text, p_note text) returns int language plpgsql security definer set search_path='' as $f$
declare n int;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can settle a staff tab.'; end if;
  if p_how not in ('cash','transfer','wages','free') then raise exception 'Choose how it was settled.'; end if;
  update public.staff_charges set settled_at=now(), settled_by=private.my_staff_id(), settled_how=p_how, settled_note=nullif(left(btrim(coalesce(p_note,'')),200),'')
    where staff_id=p_staff and settled_at is null and not voided;
  get diagnostics n = row_count;
  return n;
end $f$;
revoke all on function public.staff_tab_settle(uuid, text, text) from public, anon;
grant execute on function public.staff_tab_settle(uuid, text, text) to authenticated;

create or replace function public.staff_charge_remove(p_id uuid) returns void language plpgsql security definer set search_path='' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can remove a charge.'; end if;
  if exists (select 1 from public.staff_charges where id=p_id and order_id is not null) then raise exception 'This came from the till. Remove it there with Remove a mistake, so the stock and sales are right.'; end if;
  update public.staff_charges set voided=true where id=p_id and settled_at is null;
end $f$;
revoke all on function public.staff_charge_remove(uuid) from public, anon;
grant execute on function public.staff_charge_remove(uuid) to authenticated;

-- each staff member can see their own tab
create or replace function public.staff_tab_mine() returns jsonb language sql stable security definer set search_path='' as $f$
  select jsonb_build_object('owed', coalesce((select sum(c.amount_thb) from public.staff_charges c where c.staff_id=private.my_staff_id() and c.settled_at is null and not c.voided),0),
    'charges', coalesce((select jsonb_agg(jsonb_build_object('day', c.day, 'description', c.description, 'amount', c.amount_thb) order by c.created_at desc)
      from public.staff_charges c where c.staff_id=private.my_staff_id() and c.settled_at is null and not c.voided),'[]'::jsonb))
$f$;
revoke all on function public.staff_tab_mine() from public, anon;
grant execute on function public.staff_tab_mine() to authenticated;
