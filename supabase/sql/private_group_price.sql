-- Privates priced by people and coaches (feature private_group_price, on unless switched off): a private package can list prices
-- for more people or more coaches, for example 1 person with 1 coach 900, 2 people with 1 coach 1,400, 2 people with 2 coaches 1,800.
-- The price written is for one session at the package's normal rate; packs and amounts keep their discount in the same proportion.
-- The customer (or the front desk) picks how many people and coaches when buying, and the pack remembers it.

alter table public.packages add column if not exists group_prices jsonb;
alter table public.packages add column if not exists badge text;
alter table public.packages add column if not exists was_thb integer;
alter table public.purchases add column if not exists people smallint;
alter table public.purchases add column if not exists coaches smallint;

-- how much more (or less) a session costs for this many people and coaches; null when that is not on sale
create or replace function private.group_ratio(p_package uuid, p_people integer, p_coaches integer) returns numeric
language sql stable security definer set search_path to '' as $f$
  select case when coalesce(p_people, 1) = 1 and coalesce(p_coaches, 1) = 1 then 1::numeric
    when not private.feature('private_group_price', true) then null
    else (select (g->>'price')::numeric from jsonb_array_elements(coalesce(k.group_prices, '[]'::jsonb)) g
          where (g->>'people')::int = p_people and (g->>'coaches')::int = p_coaches limit 1)
       / nullif(coalesce(private.tier_unit(k.tiers, 1)::numeric, k.price_thb::numeric / greatest(coalesce(k.visit_limit, 1), 1)), 0) end
  from public.packages k where k.id = p_package
$f$;

create or replace function private.group_label(p_people integer, p_coaches integer) returns text language sql immutable as $f$
  select p_people || case when p_people = 1 then ' person, ' else ' people, ' end || p_coaches || case when p_coaches = 1 then ' coach' else ' coaches' end
$f$;

-- the member app: buy a private package for a number of people and coaches
create or replace function public.customer_buy_group(p_package uuid, p_fz boolean, p_qty integer, p_people integer, p_coaches integer) returns uuid
language plpgsql security definer set search_path to '' as $f$
declare k public.packages; r numeric; v_id uuid; grp text; addon integer := 0; pr public.purchases;
begin
  if coalesce(p_people, 1) not between 1 and 20 or coalesce(p_coaches, 1) not between 1 and 10 then raise exception 'Choose how many people and coaches.'; end if;
  select * into k from public.packages where id = p_package and active;
  if not found then raise exception 'That package is not on sale.'; end if;
  r := private.group_ratio(p_package, coalesce(p_people, 1), coalesce(p_coaches, 1));
  if r is null then raise exception 'That number of people and coaches is not on sale. Ask at the front desk.'; end if;
  grp := coalesce((select price_group from public.customers where id = private.customer_id()), 'standard');
  if jsonb_array_length(coalesce(private.tiers_for(k.tiers, k.tiers_local, grp), '[]'::jsonb)) > 0 then
    v_id := public.customer_buy_qty(p_package, p_fz, p_qty);
  else
    v_id := public.customer_buy(p_package, p_fz);
  end if;
  if coalesce(p_people, 1) > 1 or coalesce(p_coaches, 1) > 1 then
    select * into pr from public.purchases where id = v_id;
    if coalesce(p_fz, false) then addon := coalesce(private.addon_for(k.addon_fz_thb, k.addon_fz_local_thb, grp), 0); end if;
    update public.purchases set
      price_thb = (round((pr.price_thb - addon) * r / 10) * 10)::int + addon,
      package_name = replace(pr.package_name, ' + Fitness Zone', '') || ', ' || private.group_label(p_people, p_coaches) || case when coalesce(p_fz, false) then ' + Fitness Zone' else '' end,
      people = p_people, coaches = p_coaches
    where id = v_id;
  end if;
  return v_id;
end $f$;
revoke all on function public.customer_buy_group(uuid, boolean, integer, integer, integer) from public, anon;
grant execute on function public.customer_buy_group(uuid, boolean, integer, integer, integer) to authenticated;

-- the member app sees the prices for more people and coaches
do $p$
declare d text; n text;
begin
  foreach d in array array['public.customer_home()', 'public.customer_home_as(uuid)'] loop
    if to_regprocedure(d) is null then continue; end if;
    n := pg_get_functiondef(d::regprocedure);
    if position('group_prices' in n) > 0 then continue; end if;
    if position($x$'qty_unit', g.qty_unit)$x$ in n) = 0 then raise notice '% older version, skipped', d; continue; end if;
    execute replace(n, $x$'qty_unit', g.qty_unit)$x$, $x$'qty_unit', g.qty_unit, 'group_prices', case when private.feature('private_group_price', true) then g.group_prices end)$x$);
    if position('group_prices' in pg_get_functiondef(d::regprocedure)) = 0 then raise exception '% patch did not apply', d; end if;
  end loop;
end $p$;

notify pgrst, 'reload schema';
