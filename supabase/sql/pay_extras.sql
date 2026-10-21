-- Card payment fee and tax on packages and privates.
-- price_thb stays the full amount the customer pays (so owed, paid and Stripe all keep working).
-- fee_thb and tax_thb say how much of it is the card fee and the tax. Coaches' commission and the
-- per session value of a private pack leave them out. Accounts shows them as their own lines.

alter table public.purchases add column if not exists fee_thb integer not null default 0;
alter table public.purchases add column if not exists tax_thb integer not null default 0;
alter table public.privates  add column if not exists fee_thb integer not null default 0;
alter table public.privates  add column if not exists tax_thb integer not null default 0;
do $$ begin
  alter table public.purchases add constraint purchases_extras_ok check (fee_thb >= 0 and tax_thb >= 0);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.privates add constraint privates_extras_ok check (fee_thb >= 0 and tax_thb >= 0);
exception when duplicate_object then null; end $$;

-- the default rates the tick boxes use
insert into public.app_settings(key, value) values ('pay_extras', '{"card_pct":3,"tax_pct":7}') on conflict (key) do nothing;

-- add a card fee or tax to something already sold (before taking the payment)
create or replace function public.add_pay_extras(p_kind text, p_id uuid, p_fee integer, p_tax integer) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare f integer := greatest(0, coalesce(p_fee,0)); t integer := greatest(0, coalesce(p_tax,0)); r jsonb;
begin
  if not private.is_desk() then raise exception 'Only front desk or a manager can do this.'; end if;
  if f = 0 and t = 0 then raise exception 'Type the fee or the tax.'; end if;
  if p_kind = 'purchase' then
    update public.purchases set price_thb = price_thb + f + t, fee_thb = fee_thb + f, tax_thb = tax_thb + t
      where id = p_id and not cancelled and price_thb > paid_thb returning jsonb_build_object('price', price_thb, 'paid', paid_thb) into r;
    if r is null then raise exception 'That is already paid or was cancelled.'; end if;
  elsif p_kind = 'private' then
    update public.privates set price_thb = price_thb + f + t, fee_thb = fee_thb + f, tax_thb = tax_thb + t
      where id = p_id and purchase_id is null and not paid and status <> 'cancelled' returning jsonb_build_object('price', price_thb) into r;
    if r is null then raise exception 'That private is already paid.'; end if;
  else raise exception 'Unknown kind.'; end if;
  return r;
end $f$;
grant execute on function public.add_pay_extras(text, uuid, integer, integer) to authenticated;

do $$
declare d text; n text;
begin
  -- a pack's value per session leaves out the card fee and tax
  d := pg_get_functiondef('private.guard_private()'::regprocedure);
  n := replace(d, 'new.price_thb := round(pk.price_thb::numeric / pk.visit_limit);', 'new.price_thb := round((pk.price_thb - pk.fee_thb - pk.tax_thb)::numeric / pk.visit_limit);');
  if n <> d then execute n; elsif position('pk.fee_thb' in d) = 0 then raise exception 'guard_private not changed'; end if;

  d := pg_get_functiondef('private.pack_price_follow()'::regprocedure);
  n := replace(d, 'round(new.price_thb::numeric / new.visit_limit)', 'round((new.price_thb - new.fee_thb - new.tax_thb)::numeric / new.visit_limit)');
  if n <> d then execute n; elsif position('new.fee_thb' in d) = 0 then raise exception 'pack_price_follow not changed'; end if;

  d := pg_get_functiondef('public.customer_request_private(uuid,date,time without time zone,text)'::regprocedure);
  n := replace(d, 'round(v_pack.price_thb::numeric / v_pack.visit_limit)', 'round((v_pack.price_thb - v_pack.fee_thb - v_pack.tax_thb)::numeric / v_pack.visit_limit)');
  if n <> d then execute n; elsif position('v_pack.fee_thb' in d) = 0 then raise exception 'customer_request_private not changed'; end if;

  -- coach booking: the coach gets back their share, never the price
  d := pg_get_functiondef('public.coach_book_private(uuid,time without time zone,text,text)'::regprocedure);
  n := replace(d, 'round(v_pack.price_thb::numeric / v_pack.visit_limit)', 'round((v_pack.price_thb - v_pack.fee_thb - v_pack.tax_thb)::numeric / v_pack.visit_limit)');
  n := replace(n, '''price'', v_price,', '''share'', round(v_price * coalesce(v_pct, 50) / 100.0),');
  if n <> d then execute n; elsif position('v_pack.fee_thb' in d) = 0 then raise exception 'coach_book_private not changed'; end if;

  -- commission on the price without the card fee and tax
  d := pg_get_functiondef('public.coach_home()'::regprocedure);
  n := replace(d, '''share_thb'', round(p.price_thb * p.coach_pct / 100.0)', '''share_thb'', round((p.price_thb - p.fee_thb - p.tax_thb) * p.coach_pct / 100.0)');
  if n <> d then execute n; elsif position('p.fee_thb' in d) = 0 then raise exception 'coach_home not changed'; end if;

  d := pg_get_functiondef('public.commission_pay(uuid,date,date,text)'::regprocedure);
  n := replace(d, 'coalesce(p.price_thb,0)', '(coalesce(p.price_thb,0) - p.fee_thb - p.tax_thb)');
  if n <> d then execute n; elsif position('p.fee_thb' in d) = 0 then raise exception 'commission_pay not changed'; end if;

  d := pg_get_functiondef('private.privates_payout_lock()'::regprocedure);
  n := replace(d, 'new.price_thb is distinct from old.price_thb or', 'new.price_thb is distinct from old.price_thb or new.fee_thb is distinct from old.fee_thb or new.tax_thb is distinct from old.tax_thb or');
  if n <> d then execute n; elsif position('new.fee_thb' in d) = 0 then raise exception 'privates_payout_lock not changed'; end if;

  -- Accounts: the card fee and tax part of each payment as their own lines
  d := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  n := replace(d,
'''in'', case when p.stay_id is not null then ''Stay payment'' when p.private_id is not null then ''Private'' else coalesce(k.package_name,''Payment'') end,
    ''Sales'', p.method, p.amount_thb::numeric, ''payment'', p.id, null::text
  from public.payments p left join public.purchases k on k.id = p.purchase_id
  where not p.voided and p.method <> ''before_app'' and p.day between p_from and p_to and p.amount_thb <> 0',
'''in'', case x.part when ''fee'' then ''Card fee: '' when ''tax'' then ''Tax: '' else '''' end || case when p.stay_id is not null then ''Stay payment'' when p.private_id is not null then ''Private'' else coalesce(k.package_name,''Payment'') end,
    case x.part when ''fee'' then ''Card fees charged'' when ''tax'' then ''Tax collected'' else ''Sales'' end, p.method, x.amt::numeric, ''payment'', p.id, null::text
  from public.payments p left join public.purchases k on k.id = p.purchase_id left join public.privates pv on pv.id = p.private_id
    cross join lateral (select coalesce(k.price_thb, pv.price_thb) pr, coalesce(k.fee_thb, pv.fee_thb, 0) fe, coalesce(k.tax_thb, pv.tax_thb, 0) tx) z
    cross join lateral (select case when z.pr > 0 and z.fe > 0 then round(p.amount_thb::numeric * z.fe / z.pr) else 0 end f,
                               case when z.pr > 0 and z.tx > 0 then round(p.amount_thb::numeric * z.tx / z.pr) else 0 end t) w
    cross join lateral (values (''main'', p.amount_thb - w.f - w.t), (''fee'', w.f), (''tax'', w.t)) x(part, amt)
  where not p.voided and p.method <> ''before_app'' and p.day between p_from and p_to and p.amount_thb <> 0 and x.amt <> 0');
  if n <> d then execute n; elsif position('Card fees charged' in d) = 0 then raise exception 'acc_lines not changed'; end if;
end $$;
