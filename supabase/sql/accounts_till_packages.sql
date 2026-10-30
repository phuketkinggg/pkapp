-- Accounts: training packages, privates and passes sold on the till now count as money in.
-- Till lines that are packages were left out of the shop lines (so they are not counted twice) but the till takes
-- no separate payment for them, so they were missing from the accounts. They now count on the day of the sale,
-- in the same department as a package paid in the app (Gym training, Privates, Spa, Visa and DTV, the cafe),
-- unless the package was also paid in the app.
do $p$
declare d text; n text; mark text := '  union all
  -- till sales put on a room bill: counted when the bill is settled';
begin
  if to_regprocedure('private.acc_lines(date,date)') is null then raise notice 'no acc_lines, skipped'; return; end if;
  d := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  if position('-- packages sold on the till' in d) > 0 then raise notice 'acc_lines already patched'; return; end if;
  if position(mark in d) = 0 then raise notice 'acc_lines: older version, skipped'; return; end if;
  n := replace(d, mark, '  union all
  -- packages sold on the till (training, privates, passes): the till line is the payment
  select (o.paid_at at time zone ''Asia/Bangkok'')::date,
    coalesce(ov.b, case when private.zone_of_covers(k.covers)=''cafe'' then private.biz_stay() else private.biz_main() end),
    coalesce(ov.d, case when private.zone_of_covers(k.covers)=''cafe'' then private.dept_cafe()
         when private.zone_of_covers(k.covers)=''spa'' then ''Spa''
         when k.package_name ilike ''%dtv%'' or k.package_name ilike ''%visa%'' then ''Visa and DTV''
         when ''Privates'' = any(k.covers) then ''Privates''
         when private.zone_of_covers(k.covers)=''other'' then ''Other''
         else ''Gym training'' end),
    ''in'', coalesce(k.package_name, i.name), ''Sales'', o.method,
    round(i.qty * i.price_thb * case when o.subtotal_thb > 0 then (o.total_thb - o.fee_thb - o.tax_thb)::numeric / o.subtotal_thb else 1 end, 2), ''shop'', o.id, null
  from public.shop_orders o join public.shop_order_items i on i.order_id = o.id and not i.removed and i.purchase_id is not null
    join public.purchases k on k.id = i.purchase_id
    left join lateral (select pg.acc_business b, pg.acc_department d from public.packages pg where pg.id = k.package_id and pg.acc_business is not null) ov on true
  where o.status = ''paid'' and o.paid_at is not null and (o.paid_at at time zone ''Asia/Bangkok'')::date between p_from and p_to
    and not exists (select 1 from public.payments py where py.purchase_id = k.id and not py.voided and py.method <> ''before_app'')
' || mark);
  execute n;
  if position('-- packages sold on the till' in pg_get_functiondef('private.acc_lines(date,date)'::regprocedure)) = 0 then raise exception 'acc_lines patch did not apply'; end if;
end $p$;
notify pgrst, 'reload schema';
