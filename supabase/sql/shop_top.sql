-- Most used at the till (feature: shop_top): the products sold most at this shop in the last 30 days,
-- shown as the first row on the till so staff find them in one tap.

create or replace function public.shop_top(p_location uuid, p_days int default 30, p_limit int default 12) returns jsonb
language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(x.product_id order by x.n desc) from (
    select i.product_id, sum(i.qty) n
    from public.shop_order_items i join public.shop_orders o on o.id = i.order_id
    join public.shop_products p on p.id = i.product_id and p.active
    where i.product_id is not null and not coalesce(i.removed, false)
      and o.status in ('paid','room','waiting') and o.created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 365))
      and (p_location is null or o.location_id = p_location)
    group by i.product_id order by n desc limit least(greatest(coalesce(p_limit, 12), 1), 40)) x), '[]'::jsonb);
end $f$;
revoke all on function public.shop_top(uuid, int, int) from public, anon;
grant execute on function public.shop_top(uuid, int, int) to authenticated;
notify pgrst, 'reload schema';
