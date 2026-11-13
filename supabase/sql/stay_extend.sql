-- Extend a stay whose bill is already settled (feature stay_extend_reopen, on unless switched off): the paid bill becomes a closed
-- part of the bill (like a weekly bill: paid up to the old leaving date, its payment kept), the bill opens again, and only the new
-- nights (and anything added from now) are owed. Before, the stay stayed settled and the extra nights were never charged.
-- Needs bill_periods.sql. Patches check they applied and skip cleanly where a database is older.

-- reopening the bill for an extension keeps every payment (a manager reopening by hand still takes back the final payment)
do $p$
declare d text; n text;
begin
  if to_regprocedure('private.stay_settled()') is null then raise notice 'no stays here, skipped'; return; end if;
  d := pg_get_functiondef('private.stay_settled()'::regprocedure);
  if position('pk.extend' in d) > 0 then raise notice 'stay_settled already patched'; return; end if;
  n := replace(d, $x$  elsif not new.settled and coalesce(old.settled,false) then$x$,
    $x$  elsif not new.settled and coalesce(old.settled,false) and coalesce(current_setting('pk.extend', true), '') <> '1' then$x$);
  if n = d then raise notice 'stay_settled: older version, skipped'; return; end if;
  execute n;
  if position('pk.extend' in pg_get_functiondef('private.stay_settled()'::regprocedure)) = 0 then raise exception 'stay_settled patch did not apply'; end if;
end $p$;

create or replace function public.stay_extend(p_stay uuid, p_check_out date, p_add_thb integer) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare s public.stays; start_d date; room_before int; room int; ch int; till int; pid uuid; payamt int; per jsonb; credit int; reopened boolean := false;
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  select * into s from public.stays where id = p_stay for update;
  if not found then raise exception 'Stay not found.'; end if;
  if s.status not in ('booked','in','out') then raise exception 'This stay is cancelled.'; end if;
  if p_check_out is null or p_check_out <= s.check_out then raise exception 'Pick a leaving date after %.', to_char(s.check_out, 'DD Mon'); end if;
  if coalesce(p_add_thb, 0) < 0 then raise exception 'Type the price for the extra nights.'; end if;
  if s.settled and private.feature('stay_extend_reopen', true) then
    -- the settled bill becomes a closed part: paid up to the old leaving date
    select max((x->>'upto')::date), coalesce(sum((x->>'room')::int), 0) into start_d, room_before from jsonb_array_elements(s.bill_periods) x;
    start_d := coalesce(start_d, s.check_in);
    room := greatest(0, coalesce(s.room_price_thb, 0) - room_before);
    select coalesce(sum(amount_thb), 0)::int, coalesce(sum(amount_thb) filter (where order_id is not null), 0)::int into ch, till
      from public.room_charges where stay_id = s.id and not coalesce(voided, false) and day >= start_d
        and not (private_id is not null and coalesce(amount_thb, 0) = 0);
    select id, amount_thb into pid, payamt from public.payments
      where stay_id = s.id and not voided and note = 'Room bill' order by at desc limit 1;
    credit := greatest(0, room + ch - coalesce(payamt, 0) - till);
    per := jsonb_build_object('id', gen_random_uuid(), 'from', start_d, 'upto', s.check_out, 'nights', s.check_out - start_d, 'room', room, 'charges', ch,
      'till', till, 'credit', credit, 'total', room + ch - credit, 'method', coalesce(s.settled_method, 'cash'), 'paid_on', coalesce(s.settled_on, private.bkk_today()),
      'payment_id', pid, 'by', (select name from public.staff where id = private.my_staff_id()), 'at', now(), 'extended', true);
    -- the settle payment now belongs to that part, so it counts as paid ahead on the new bill
    if pid is not null then update public.payments set note = 'Room bill to ' || to_char(s.check_out, 'DD Mon YYYY') where id = pid; end if;
    perform set_config('pk.extend', '1', true);
    update public.stays set bill_periods = bill_periods || jsonb_build_array(per), settled = false where id = s.id;
    perform set_config('pk.extend', '', true);
    reopened := true;
  end if;
  update public.stays set check_out = p_check_out, room_price_thb = coalesce(room_price_thb, 0) + coalesce(p_add_thb, 0), room_price_manual = true,
    status = case when status = 'out' and p_check_out > private.bkk_today() then 'in' else status end
  where id = s.id;
  return jsonb_build_object('reopened', reopened, 'owed', private.stay_due(s.id) - private.stay_till_total(s.id));
end $f$;
revoke all on function public.stay_extend(uuid, date, integer) from public, anon;
grant execute on function public.stay_extend(uuid, date, integer) to authenticated;

notify pgrst, 'reload schema';
