-- Package upgrades (Settings, Packages, Upgrade offers): a customer on one package can move up to a better one
-- (for example a weekly class pass to unlimited) for the difference in price, less for the time already used.
-- The upgrade is an order of its own. When it is paid in full, the package they have takes on the new package's
-- rules (what it covers, times, visits and weekly limit), keeping its dates.
-- Paths live in app_settings key 'upgrades': [{"from": package id, "to": package id, "price": fixed THB or null}].
-- Feature switch: upgrades (on unless turned off).

alter table public.purchases add column if not exists upgrade_of uuid references public.purchases(id) on delete set null;
alter table public.purchases add column if not exists upgrade_done_at timestamptz;
create index if not exists purchases_upgrade_of on public.purchases (upgrade_of) where upgrade_of is not null;

-- the upgrade paths
create or replace function private.upgrade_paths() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end
  from (select coalesce((select value::jsonb from public.app_settings where key = 'upgrades'), '[]'::jsonb) v) x
$f$;

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
    'pending', (select u.id from public.purchases u where u.upgrade_of = p.id and not u.cancelled and u.upgrade_done_at is null and not u.paid limit 1));
end $f$;

-- the upgrades a customer can take: their own (customer app) or any customer's (front desk)
create or replace function public.upgrade_offers(p_customer uuid default null) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare cid uuid;
begin
  if p_customer is null then cid := private.customer_id();
  elsif private.is_desk() then cid := p_customer;
  else raise exception 'Not allowed.'; end if;
  if cid is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(q order by q->>'from') from (select private.upgrade_quote(p.id) q from public.purchases p
    where p.customer_id = cid and not p.cancelled and p.upgrade_of is null and p.package_id is not null) z where q is not null), '[]'::jsonb);
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
  if q->>'pending' is not null then return (q->>'pending')::uuid; end if;
  insert into public.purchases (customer_id, package_id, package_name, price_thb, price_group, paid, purchased_on, covers, times,
                                duration_days, starts_on, expires_on, ordered_in_app, upgrade_of)
  values (p.customer_id, (q->>'to_id')::uuid, 'Upgrade: ' || p.package_name || ' to ' || (q->>'to'), (q->>'price')::int, p.price_group, false, today,
          '{}'::text[], null, 1, today, today, true, p.id)
  returning id into v;
  return v;
end $f$;

-- paid in full: the package takes on the new rules
create or replace function private.upgrade_apply() returns trigger language plpgsql security definer set search_path to '' as $f$
declare b public.packages; o public.purchases; cname text;
begin
  if new.upgrade_of is null or new.upgrade_done_at is not null or new.cancelled or not new.paid then return null; end if;
  select * into o from public.purchases where id = new.upgrade_of;
  select * into b from public.packages where id = new.package_id;
  if o.id is null or b.id is null then return null; end if;
  update public.purchases set package_id = b.id, package_name = b.name, covers = b.covers, times = b.times,
      visit_limit = b.visit_limit, visits_left = case when b.visit_limit is null then null else greatest(0, b.visit_limit - coalesce(o.visit_limit - o.visits_left, 0)) end,
      per_week_limit = b.per_week_limit
    where id = o.id;
  update public.purchases set upgrade_done_at = now() where id = new.id;
  select name into cname from public.customers where id = new.customer_id;
  insert into public.notices (kind, customer_id, ref_id, title, detail)
    values ('package', new.customer_id, o.id, 'Upgrade paid: ' || coalesce(cname, 'customer'),
            o.package_name || ' is now ' || b.name || ' (' || to_char(new.price_thb, 'FM999,999,990') || ' THB).');
  return null;
end $f$;

drop trigger if exists purchases_upgrade_apply on public.purchases;
create trigger purchases_upgrade_apply after insert or update of paid on public.purchases for each row execute function private.upgrade_apply();

-- the customer app: a finished upgrade order is not shown as a package
do $p$
declare fn text; d text; n text;
  old text := 'where p.customer_id = c.id and not p.cancelled';
  neu text := 'where p.customer_id = c.id and not p.cancelled and p.upgrade_done_at is null';
begin
  foreach fn in array array['public.customer_home()', 'public.customer_home_as(uuid)'] loop
    if to_regprocedure(fn) is null then raise notice '% not here, skipped', fn; continue; end if;
    d := pg_get_functiondef(to_regprocedure(fn));
    if position('upgrade_done_at' in d) > 0 then raise notice '% already patched', fn;
    elsif position(old in d) = 0 then raise notice '%: older version, skipped', fn;
    else
      n := replace(d, old, neu); execute n;
      if position('upgrade_done_at' in pg_get_functiondef(to_regprocedure(fn))) = 0 then raise exception '% patch did not apply', fn; end if;
    end if;
  end loop;
end $p$;

revoke all on function private.upgrade_paths(), private.upgrade_quote(uuid), private.upgrade_apply() from public, anon, authenticated;
revoke all on function public.upgrade_offers(uuid), public.upgrade_order(uuid) from public, anon;
grant execute on function public.upgrade_offers(uuid), public.upgrade_order(uuid) to authenticated;
notify pgrst, 'reload schema';
