-- Card fee always charged (feature card_fee_lock, on unless switched off): when the front desk or anyone who is not a
-- manager sells a package, books a private or rings up a till sale paid by card, the card fee must be on it.
-- Only a manager can let a customer off the card fee or lower it. Customers, coaches booking from a pack and the
-- system itself (no signed in staff) are not checked.

-- the card fee on an amount, from Settings, Card fee and tax (same as the app: a percent plus a fixed part under a limit)
create or replace function private.card_fee_for(p_base integer) returns integer language plpgsql stable security definer set search_path to '' as $f$
declare px jsonb; pct numeric := 3; fixed numeric := 10; under numeric := 2000;
begin
  if coalesce(p_base, 0) <= 0 then return 0; end if;
  begin select value::jsonb into px from public.app_settings where key = 'pay_extras'; exception when others then px := null; end;
  if px is not null then
    begin pct := coalesce(nullif(px->>'card_pct','')::numeric, pct); exception when others then null; end;
    begin fixed := coalesce(nullif(px->>'card_fixed','')::numeric, fixed); exception when others then null; end;
    begin under := coalesce(nullif(px->>'card_fixed_under','')::numeric, under); exception when others then null; end;
  end if;
  return round(p_base * pct / 100)::int + case when fixed > 0 and p_base < under then round(fixed)::int else 0 end;
end $f$;
revoke all on function private.card_fee_for(integer) from public, anon;

create or replace function private.card_fee_guard() returns trigger language plpgsql security definer set search_path to '' as $f$
declare r text; base integer; need integer; n jsonb := to_jsonb(new); o jsonb;
begin
  if new.method is distinct from 'card' then return new; end if;
  if not private.feature('card_fee_lock', true) then return new; end if;
  select s.role into r from public.staff s where s.user_id = (select auth.uid()) and s.active limit 1;
  if r is null or r = 'manager' then return new; end if;
  if tg_table_name = 'shop_orders' then
    -- the till: the sale turns from being rung up (void) to paid by card
    o := to_jsonb(old);
    if tg_op <> 'UPDATE' or coalesce(o->>'status','') <> 'void' then return new; end if;
    base := coalesce((n->>'subtotal_thb')::int, 0) - coalesce((n->>'discount_thb')::int, 0);
  else
    if tg_op <> 'INSERT' then return new; end if;
    if nullif(n->>'purchase_id','') is not null or nullif(n->>'shop_order_id','') is not null then return new; end if;
    base := coalesce((n->>'price_thb')::int, 0) - coalesce((n->>'fee_thb')::int, 0) - coalesce((n->>'tax_thb')::int, 0) - coalesce((n->>'adds_thb')::int, 0);
  end if;
  need := private.card_fee_for(base);
  if coalesce((n->>'fee_thb')::int, 0) < need - 1 then
    raise exception 'Card payments have a card fee of % THB. Only a manager can let them off it.', need;
  end if;
  return new;
end $f$;

do $p$
declare t text;
begin
  foreach t in array array['purchases','privates','shop_orders'] loop
    if to_regclass('public.' || t) is null then raise notice '% missing, skipped', t; continue; end if;
    if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'fee_thb') then raise notice '% has no fee_thb, skipped', t; continue; end if;
    execute format('drop trigger if exists card_fee_guard on public.%I', t);
    execute format('create trigger card_fee_guard before %s on public.%I for each row execute function private.card_fee_guard()', case when t = 'shop_orders' then 'update' else 'insert' end, t);
  end loop;
end $p$;
