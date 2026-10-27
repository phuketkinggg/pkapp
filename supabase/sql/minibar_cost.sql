-- Mini bar profit: each item can have what you pay for it (cost). Empty = the cost of the shop product with the same name.
-- The cost is kept on each mini bar charge when housekeeping adds it, so profit stays right when prices change later.
alter table public.minibar_items add column if not exists cost_thb integer check (cost_thb is null or cost_thb >= 0);
alter table public.room_charges add column if not exists cost_thb integer;

create or replace function private.mb_cost(m public.minibar_items) returns integer language sql stable security definer set search_path to '' as $$
  select coalesce(m.cost_thb, (select p.cost_thb from public.shop_products p where lower(btrim(p.name)) = lower(btrim(m.name)) and p.cost_thb is not null order by p.cost_thb limit 1))
$$;

-- the shop cost for each mini bar item, for the settings list
create or replace function public.minibar_costs() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_object_agg(m.id, jsonb_build_object('cost', private.mb_cost(m), 'from_shop', m.cost_thb is null and private.mb_cost(m) is not null)), '{}'::jsonb)
  from public.minibar_items m where private.staff_role() is not null
$$;
revoke all on function public.minibar_costs() from public, anon;
grant execute on function public.minibar_costs() to authenticated;

do $$ declare s text;
begin
  s := pg_get_functiondef('public.hk_minibar(uuid,jsonb)'::regprocedure);
  if s like '%mb_cost%' then return; end if;
  s := replace(s, 'select m.name, m.price_thb, least(', 'select m.name, m.price_thb, private.mb_cost(m) as cost, least(');
  s := replace(s, 'insert into public.room_charges (stay_id, description, amount_thb, kind, created_by)', 'insert into public.room_charges (stay_id, description, amount_thb, kind, created_by, cost_thb)');
  s := replace(s, $a$it.price_thb * it.qty, 'minibar', v_staff);$a$, $a$it.price_thb * it.qty, 'minibar', v_staff, it.cost * it.qty);$a$);
  if s not like '%mb_cost(m) as cost%' or s not like '%created_by, cost_thb)%' or s not like '%it.cost * it.qty%' then raise notice 'hk_minibar is a different version here: skipped.'; return; end if;
  execute s;
end $$;

-- or pick the same item in the shop, when the names differ (Chang in the mini bar, Chang beer 320ml in the shop)
alter table public.minibar_items add column if not exists shop_product_id uuid references public.shop_products(id) on delete set null;
create or replace function private.mb_cost(m public.minibar_items) returns integer language sql stable security definer set search_path to '' as $$
  select coalesce(m.cost_thb,
    (select p.cost_thb from public.shop_products p where p.id = m.shop_product_id),
    (select p.cost_thb from public.shop_products p where lower(btrim(p.name)) = lower(btrim(m.name)) and p.cost_thb is not null order by p.cost_thb limit 1))
$$;
