-- Who is in the room (feature stay_sell): the names of everyone staying, and packages sold from a stay charged to its room bill,
-- also for a friend or partner in the room who is not the person who booked.
alter table public.stays add column if not exists guest_names text;

-- Charge to room: a package with for_stay set goes on that stay's bill (the guest's own, or a friend's in the same room);
-- without it, on the customer's own stay today, as before. A friend's package says who it is for on the bill.
-- Patch: checks it applied, skips cleanly where the function is older.
do $patch$
declare d text; n text;
begin
  if to_regprocedure('private.charge_purchase_to_room()') is null then raise notice 'stay_guests: no charge_purchase_to_room here, skipped'; return; end if;
  d := pg_get_functiondef('private.charge_purchase_to_room()'::regprocedure);
  if position('new.for_stay' in d) > 0 then raise notice 'stay_guests: room charge already applied'; return; end if;
  n := regexp_replace(d,
    'select s\.id into v_stay from public\.stays s\s+where s\.customer_id = new\.customer_id',
    'if new.for_stay is not null then select s.id into v_stay from public.stays s where s.id = new.for_stay and s.status in (''booked'',''in'') and not s.settled; if v_stay is null then raise exception ''That stay is closed or settled, so it cannot go on its room bill.''; end if; end if; if v_stay is null then select s.id into v_stay from public.stays s where s.customer_id = new.customer_id');
  n := replace(n, 'order by s.check_in desc limit 1;', 'order by s.check_in desc limit 1; end if;');
  n := replace(n, 'values (v_stay, new.package_name, new.price_thb',
    'values (v_stay, new.package_name || coalesce((select '', for '' || c.name from public.customers c join public.stays s2 on s2.id = v_stay where c.id = new.customer_id and s2.customer_id is distinct from new.customer_id), ''''), new.price_thb');
  if n = d then raise notice 'stay_guests: charge_purchase_to_room is a different version here, skipped'; return; end if;
  execute n;
  if position('new.for_stay' in pg_get_functiondef('private.charge_purchase_to_room()'::regprocedure)) = 0 then raise exception 'stay_guests: room charge patch did not apply'; end if;
end $patch$;

-- A package charged to the room is paid by the room bill: no payment is recorded for it now (the money comes in when the bill is settled),
-- so it is not counted twice.
do $patch$
declare d text; n text;
begin
  if to_regprocedure('private.purchase_paid_now()') is null then raise notice 'stay_guests: no purchase_paid_now here, skipped'; return; end if;
  d := pg_get_functiondef('private.purchase_paid_now()'::regprocedure);
  if position('''room''' in d) > 0 then raise notice 'stay_guests: paid now already applied'; return; end if;
  n := regexp_replace(d, 'begin\s+amt :=', 'begin' || E'\n  if new.method = ''room'' then return null; end if;\n  amt :=');
  if n = d then raise notice 'stay_guests: purchase_paid_now is a different version here, skipped'; return; end if;
  execute n;
  if position('''room''' in pg_get_functiondef('private.purchase_paid_now()'::regprocedure)) = 0 then raise exception 'stay_guests: paid now patch did not apply'; end if;
end $patch$;
