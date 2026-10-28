-- Package upgrades, part 2: the offer pops up when the customer checks in (desk screen or their app),
-- once, unless they already upgraded or the team already spoke to them. Each upgrade path can have its own words:
-- "have" (what their package gives) and "get" (what the upgrade gives).
alter table public.purchases add column if not exists upgrade_offered_at timestamptz;

-- what one purchase can upgrade to, and the price today (null: no upgrade)
create or replace function private.upgrade_quote(p_purchase uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare p public.purchases; c public.customers; a public.packages; b public.packages; path jsonb; base int; pa int; pb int;
  today date := private.bkk_today(); total int; left_days int; price int;
begin
  if not private.feature('upgrades', true) then return null; end if;
  select * into p from public.purchases where id = p_purchase;
  if p.id is null or p.cancelled or p.refunded_at is not null or p.upgrade_of is not null or p.package_id is null then return null; end if;
  if not p.paid and p.ordered_in_app then return null; end if;                       -- not paid yet: nothing to upgrade
  if p.expires_on is not null and p.expires_on < today then return null; end if;      -- over
  if p.starts_on is null and p.start_by is not null and p.start_by < today then return null; end if;
  select x into path from jsonb_array_elements(private.upgrade_paths()) x where x->>'from' = p.package_id::text limit 1;
  if path is null then return null; end if;
  select * into a from public.packages where id = p.package_id;
  select * into b from public.packages where id = (path->>'to')::uuid;
  if b.id is null then return null; end if;
  select * into c from public.customers where id = p.customer_id;
  if nullif(path->>'price', '') is not null then base := (path->>'price')::int;
  else
    pa := coalesce(private.price_for(a.price_thb, a.price_local_thb, a.price_thai_thb, c.price_group), a.price_thb);
    pb := coalesce(private.price_for(b.price_thb, b.price_local_thb, b.price_thai_thb, c.price_group), b.price_thb);
    base := pb - pa;
  end if;
  if base is null or base <= 0 then return null; end if;
  price := base;
  if p.starts_on is not null and p.expires_on is not null then                        -- started: only the time left
    total := greatest(1, coalesce(p.duration_days, p.expires_on - p.starts_on + 1));
    left_days := greatest(0, p.expires_on - today + 1);
    price := ceil(base::numeric * least(left_days, total) / total / 100) * 100;
  end if;
  if price <= 0 then return null; end if;
  return jsonb_build_object('purchase_id', p.id, 'from', p.package_name, 'to', b.name, 'to_id', b.id, 'price', price, 'full', base,
    'pro_rata', price < base, 'note', coalesce(b.notes, ''), 'covers', b.covers, 'expires_on', p.expires_on, 'starts_on', p.starts_on,
    'offered', p.upgrade_offered_at is not null, 'offered_at', p.upgrade_offered_at, 'first', p.starts_on is null,
    'have', coalesce(nullif(path->>'have', ''), ''), 'get', coalesce(nullif(path->>'get', ''), ''),
    'pending', (select u.id from public.purchases u where u.upgrade_of = p.id and not u.cancelled and u.upgrade_done_at is null and not u.paid limit 1));
end $f$;

-- order the upgrade: an order waiting for payment (paid by card, PromptPay or at the desk like any order)
create or replace function public.upgrade_order(p_purchase uuid) returns uuid language plpgsql security definer set search_path to '' as $f$
declare p public.purchases; q jsonb; v uuid; today date := private.bkk_today();
begin
  select * into p from public.purchases where id = p_purchase;
  if p.id is null then raise exception 'That package was not found.'; end if;
  if not (p.customer_id = private.customer_id() or private.is_desk()) then raise exception 'Not allowed.'; end if;
  q := private.upgrade_quote(p.id);
  if q is null then raise exception 'This package cannot be upgraded.'; end if;
  update public.purchases set upgrade_offered_at = coalesce(upgrade_offered_at, now()) where id = p.id;
  if q->>'pending' is not null then return (q->>'pending')::uuid; end if;
  insert into public.purchases (customer_id, package_id, package_name, price_thb, price_group, paid, purchased_on, covers, times,
                                duration_days, starts_on, expires_on, ordered_in_app, upgrade_of)
  values (p.customer_id, (q->>'to_id')::uuid, 'Upgrade: ' || p.package_name || ' to ' || (q->>'to'), (q->>'price')::int, p.price_group, false, today,
          '{}'::text[], null, 1, today, today, true, p.id)
  returning id into v;
  return v;
end $f$;

-- the offer was shown, or the team spoke to them: it does not pop up again
create or replace function public.upgrade_seen(p_purchase uuid) returns void language plpgsql security definer set search_path to '' as $f$
begin
  update public.purchases set upgrade_offered_at = coalesce(upgrade_offered_at, now())
    where id = p_purchase and (customer_id = private.customer_id() or private.is_desk());
end $f$;

revoke all on function public.upgrade_seen(uuid) from public, anon;
grant execute on function public.upgrade_seen(uuid) to authenticated;
notify pgrst, 'reload schema';
