-- Affiliates earn on packages and courses bought on the website too (for example a DTV course), not only on room bookings.
-- The website remembers ?ref=code for 60 days and sends it with the order; when the order is paid the package is tagged to the affiliate.
-- Their share is their % of the package price (without card fee or tax). Earned once the package is paid; nothing if it is cancelled or refunded.

alter table public.purchases add column if not exists affiliate_id uuid references public.affiliates(id);
alter table public.purchases add column if not exists affiliate_pct numeric;
alter table public.web_pkg_orders add column if not exists affiliate_id uuid references public.affiliates(id);

-- the share is fixed when the package is tagged (the same rule as stays)
drop trigger if exists purchases_affiliate_pct on public.purchases;
create trigger purchases_affiliate_pct before insert or update of affiliate_id, affiliate_pct on public.purchases
  for each row execute function private.stay_affiliate_pct();

-- the buy function: tag a website order with the affiliate code
create or replace function public.affiliate_tag_order(p_order uuid, p_code text) returns boolean language plpgsql security definer set search_path to '' as $$
declare v uuid; pu uuid;
begin
  select id into v from public.affiliates where code = lower(trim(coalesce(p_code,''))) and active;
  if v is null then return false; end if;
  update public.web_pkg_orders set affiliate_id = v where id = p_order and affiliate_id is null returning purchase_id into pu;
  if pu is not null then update public.purchases set affiliate_id = v where id = pu and affiliate_id is null; end if;
  return true;
end $$;
revoke all on function public.affiliate_tag_order(uuid, text) from public, anon, authenticated;
grant execute on function public.affiliate_tag_order(uuid, text) to service_role;

-- when the order is paid and becomes a package, the package carries the affiliate
create or replace function private.web_pkg_aff_trg() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.affiliate_id is not null and new.purchase_id is not null then
    update public.purchases set affiliate_id = new.affiliate_id where id = new.purchase_id and affiliate_id is null;
  end if;
  return null;
end $$;
drop trigger if exists web_pkg_orders_aff on public.web_pkg_orders;
create trigger web_pkg_orders_aff after insert or update of purchase_id, affiliate_id on public.web_pkg_orders
  for each row execute function private.web_pkg_aff_trg();

create or replace function private.aff_pcommission(k public.purchases) returns integer language sql immutable set search_path to '' as $$
  select case when k.affiliate_id is null or k.cancelled or k.refunded_at is not null then 0
    else round((coalesce(k.price_thb,0) - coalesce(k.fee_thb,0) - coalesce(k.tax_thb,0)) * coalesce(k.affiliate_pct,0) / 100)::int end
$$;
create or replace function private.aff_pstate(k public.purchases) returns text language sql immutable set search_path to '' as $$
  select case when k.cancelled or k.refunded_at is not null then 'cancelled'
    when coalesce(k.paid_thb,0) >= coalesce(k.price_thb,0) or k.paid then 'earned' else 'coming' end
$$;

-- the affiliate's card: room stays and packages
create or replace function private.aff_row(a public.affiliates, p_full boolean) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'email', a.email, 'phone', a.phone, 'customer_id', a.customer_id,
    'pct', a.pct, 'active', a.active, 'note', a.note,
    'earned', coalesce((select sum(private.aff_commission(s)) from public.stays s where s.affiliate_id = a.id and private.aff_state(s) = 'earned'),0)
            + coalesce((select sum(private.aff_pcommission(k)) from public.purchases k where k.affiliate_id = a.id and private.aff_pstate(k) = 'earned'),0),
    'coming', coalesce((select sum(private.aff_commission(s)) from public.stays s where s.affiliate_id = a.id and private.aff_state(s) = 'coming'),0)
            + coalesce((select sum(private.aff_pcommission(k)) from public.purchases k where k.affiliate_id = a.id and private.aff_pstate(k) = 'coming'),0),
    'paid', coalesce((select sum(amount_thb) from public.affiliate_payouts where affiliate_id = a.id and not voided),0),
    'stays', coalesce((select jsonb_agg(jsonb_build_object('id', s.id,
        'guest', case when p_full then c.name else split_part(coalesce(c.name,'Guest'),' ',1) end,
        'room', case when p_full then r.name end, 'from', s.check_in, 'to', s.check_out,
        'price', case when p_full then s.room_price_thb end, 'pct', s.affiliate_pct,
        'commission', private.aff_commission(s), 'state', private.aff_state(s)) order by s.check_in desc)
      from public.stays s left join public.customers c on c.id = s.customer_id left join public.rooms r on r.id = s.room_id
      where s.affiliate_id = a.id), '[]'::jsonb),
    'sales', coalesce((select jsonb_agg(jsonb_build_object('id', k.id,
        'guest', case when p_full then c.name else split_part(coalesce(c.name,'Guest'),' ',1) end,
        'what', k.package_name, 'on', k.purchased_on,
        'price', case when p_full then coalesce(k.price_thb,0) - coalesce(k.fee_thb,0) - coalesce(k.tax_thb,0) end, 'pct', k.affiliate_pct,
        'commission', private.aff_pcommission(k), 'state', private.aff_pstate(k)) order by k.purchased_on desc)
      from public.purchases k left join public.customers c on c.id = k.customer_id
      where k.affiliate_id = a.id), '[]'::jsonb),
    'payouts', case when p_full then coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'amount', p.amount_thb, 'on', p.paid_on, 'method', p.method, 'note', p.note) order by p.paid_on desc)
      from public.affiliate_payouts p where p.affiliate_id = a.id and not p.voided), '[]'::jsonb)
      else coalesce((select jsonb_agg(jsonb_build_object('amount', p.amount_thb, 'on', p.paid_on) order by p.paid_on desc)
      from public.affiliate_payouts p where p.affiliate_id = a.id and not p.voided), '[]'::jsonb) end)
$$;
