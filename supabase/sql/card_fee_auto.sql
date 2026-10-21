-- Customers paying by card themselves (member app, kiosk, website, invoice link, booking page) always pay the card fee
-- (Settings, Card fee and tax, normally 3%). It is its own line on the Stripe page.
-- The webhook records the item amount as before, and the fee as its own money in line ("Card fees charged").

alter table public.payments add column if not exists is_fee boolean not null default false;
alter table public.payments add column if not exists fee_business text;
alter table public.payments add column if not exists fee_dept text;

create or replace function public.stripe_fee_record(p_session text, p_kind text, p_id uuid, p_fee integer) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare cid uuid; biz text := 'Phuket King Gym'; dep text := 'Card fees'; k public.purchases%rowtype; o public.shop_orders%rowtype; inv public.invoices%rowtype;
begin
  if coalesce(p_fee,0) <= 0 then return jsonb_build_object('fee', 0); end if;
  if exists (select 1 from public.payments where stripe_session = p_session || ':fee') then return jsonb_build_object('already', true); end if;
  if p_kind = 'order' then
    select * into o from public.shop_orders where id = p_id for update;
    if o.id is null or o.fee_thb > 0 then return jsonb_build_object('already', true); end if;
    update public.shop_orders set fee_thb = p_fee, total_thb = total_thb + p_fee where id = p_id;
    return jsonb_build_object('fee', p_fee);
  elsif p_kind = 'stay' then
    select customer_id into cid from public.stays where id = p_id; biz := 'Pangea Resort';
  elsif p_kind = 'purchase' then
    select * into k from public.purchases where id = p_id; cid := k.customer_id;
    if private.zone_of_covers(k.covers) = 'cafe' then biz := 'Pangea Resort'; end if;
  elsif p_kind = 'private' then
    select customer_id into cid from public.privates where id = p_id;
  elsif p_kind = 'customer' then
    cid := p_id;
  elsif p_kind = 'invoice' then
    select * into inv from public.invoices where id = p_id; cid := inv.customer_id; biz := coalesce(inv.business, biz);
  elsif p_kind = 'webpkg' then
    begin execute 'select customer_id from public.web_pkg_orders where id = $1' into cid using p_id; exception when others then cid := null; end;
  end if;
  insert into public.payments (customer_id, amount_thb, method, note, stripe_session, is_fee, fee_business, fee_dept, day)
    values (cid, p_fee, 'stripe', 'Card fee', p_session || ':fee', true, biz, dep, private.bkk_today());
  return jsonb_build_object('fee', p_fee);
end $f$;
revoke all on function public.stripe_fee_record(text, text, uuid, integer) from public, anon, authenticated;

-- Accounts: a fee payment is a Card fees charged line in its business
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  if position('fee_business' in d) > 0 then return; end if;
  n := replace(d, '  select p.day, case when k.id is not null and private.zone_of_covers(k.covers)=''cafe'' then ''Pangea Resort'' when p.stay_id is not null then ''Pangea Resort'' else ''Phuket King Gym'' end,
    case when p.stay_id is not null then ''Rooms''',
'  select p.day, coalesce(p.fee_business, case when k.id is not null and private.zone_of_covers(k.covers)=''cafe'' then ''Pangea Resort'' when p.stay_id is not null then ''Pangea Resort'' else ''Phuket King Gym'' end),
    case when p.is_fee then coalesce(p.fee_dept, ''Card fees'') when p.stay_id is not null then ''Rooms''');
  n := replace(n, '''in'', case x.part when ''fee'' then ''Card fee: '' when ''tax'' then ''Tax: '' else '''' end || case when p.stay_id',
                  '''in'', case when p.is_fee then ''Card fee: '' when x.part = ''fee'' then ''Card fee: '' when x.part = ''tax'' then ''Tax: '' else '''' end || case when p.is_fee then ''card payment'' when p.stay_id');
  n := replace(n, '    case x.part when ''fee'' then ''Card fees charged'' when ''tax'' then ''Tax collected'' else ''Sales'' end, p.method, x.amt::numeric, ''payment''',
                  '    case when p.is_fee or x.part = ''fee'' then ''Card fees charged'' when x.part = ''tax'' then ''Tax collected'' else ''Sales'' end, p.method, x.amt::numeric, ''payment''');
  if (select count(*) from regexp_matches(n, 'p\.is_fee', 'g')) < 4 then raise exception 'acc_lines not changed'; end if;
  execute n;
end $$;
