-- Money in: a package paid in parts counts as one sale. Each line now carries the purchase it paid for ('pk').
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.accounts_data(date,date)'::regprocedure);
  n := replace(d, '''id'',x.ref,''to'',x.to_b)', '''id'',x.ref,''to'',x.to_b,''pk'',case when x.src = ''payment'' then (select p.purchase_id from public.payments p where p.id = x.ref) end)');
  if n = d then raise exception 'accounts_data not changed'; end if;
  execute n;
end $$;

-- and the number of units for till lines ('q'), so Times is how many were sold
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.accounts_data(date,date)'::regprocedure);
  n := replace(d, '''pk'',case when x.src = ''payment'' then (select p.purchase_id from public.payments p where p.id = x.ref) end)',
    '''pk'',case when x.src = ''payment'' then (select p.purchase_id from public.payments p where p.id = x.ref) end,''q'',case when x.src = ''shop'' then (select sum(i.qty) from public.shop_order_items i left join public.shop_products pr on pr.id = i.product_id left join public.shop_categories c on c.id = pr.category_id where i.order_id = x.ref and not i.removed and i.purchase_id is null and coalesce(c.name,''Shop'')||'': ''||i.name = x.what) end)');
  if n <> d then execute n; end if;
end $$;
