-- Money in: a package paid in parts counts as one sale. Each line now carries the purchase it paid for ('pk').
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.accounts_data(date,date)'::regprocedure);
  n := replace(d, '''id'',x.ref,''to'',x.to_b)', '''id'',x.ref,''to'',x.to_b,''pk'',case when x.src = ''payment'' then (select p.purchase_id from public.payments p where p.id = x.ref) end)');
  if n = d then raise exception 'accounts_data not changed'; end if;
  execute n;
end $$;
