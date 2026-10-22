-- Website stays paid by Thai QR (PromptPay) straight to our bank account, no Stripe fees.
-- The guest picks Thai QR, the room is held 30 minutes while they pay; when they tap "I have paid" it is held for 12 hours
-- and the desk gets "PromptPay to check". Money is in = fully booked (same as a card payment). Not received, or 12 hours
-- without a check, gives the room back.

-- which account: one tied to the resort or cafe till if there is one, otherwise the main account
create or replace function public.web_stay_promptpay() returns jsonb language sql stable security definer set search_path to '' as $f$
  select (select jsonb_build_object('payload', a.payload, 'name', a.name) from public.promptpay_accounts a left join public.shop_locations l on l.id = a.location_id
    where coalesce(a.payload,'') <> '' order by (lower(coalesce(l.name,'')) ~ '(resort|pangea|cafe)') desc, (a.location_id is null) desc limit 1)
$f$;
revoke all on function public.web_stay_promptpay() from public, anon, authenticated;
grant execute on function public.web_stay_promptpay() to service_role;

-- what the guest owes for a website stay: the room and the extras they picked
create or replace function private.web_stay_total(p_stay uuid) returns integer language sql stable security definer set search_path to '' as $f$
  select coalesce(s.room_price_thb,0) + coalesce((select sum(k.price_thb - coalesce(k.paid_thb,0)) from public.purchases k where k.for_stay = s.id and k.ordered_in_app and not k.cancelled),0)::int
  from public.stays s where s.id = p_stay
$f$;

-- "I have paid": hold 12 hours and ask the desk to check the bank
create or replace function public.web_stay_claim(p_stay uuid) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare s public.stays; c public.customers; amt int; rm text;
begin
  select * into s from public.stays where id = p_stay and external_id like 'web:%' for update;
  if s.id is null or s.status = 'cancelled' then raise exception 'This booking ran out. Start again, or WhatsApp us if you already paid.'; end if;
  if s.hold_until is null then return jsonb_build_object('paid', true); end if;
  if exists (select 1 from public.pay_claims where kind = 'stay' and ref_id = s.id and status = 'waiting') then return jsonb_build_object('already', true); end if;
  select * into c from public.customers where id = s.customer_id;
  select name into rm from public.rooms where id = s.room_id;
  amt := private.web_stay_total(s.id);
  update public.stays set hold_until = greatest(hold_until, now() + interval '12 hours') where id = s.id;
  insert into public.pay_claims (customer_id, kind, ref_id, amount_thb, what)
    values (s.customer_id, 'stay', s.id, amt, 'Website stay: ' || rm || ', ' || to_char(s.check_in, 'FMDD Mon') || ' to ' || to_char(s.check_out, 'FMDD Mon')
      || ' (' || coalesce(c.email,'') || coalesce(', ' || c.phone, '') || '). Room held until ' || to_char((now() + interval '12 hours') at time zone 'Asia/Bangkok', 'HH24:MI FMDD Mon') || '.');
  insert into public.notices (kind, customer_id, ref_id, title, detail)
    values ('stay', s.customer_id, s.id, 'PromptPay to check: ' || c.name || ', ' || rm,
      to_char(amt, 'FM999,999,990') || ' THB for ' || to_char(s.check_in, 'FMDD Mon') || ' to ' || to_char(s.check_out, 'FMDD Mon')
      || '. Check the bank app, then tap Money is in under PromptPay to check. The room is held for 12 hours.');
  return jsonb_build_object('ok', true, 'held_until', now() + interval '12 hours');
end $f$;
revoke all on function public.web_stay_claim(uuid) from public, anon, authenticated;
grant execute on function public.web_stay_claim(uuid) to service_role;

-- the booking page asks how it is going
create or replace function public.web_booking_status(p_stay uuid) returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('paid', coalesce(s.app_paid_thb,0) > 0 or s.settled or (s.hold_until is null and s.status <> 'cancelled' and exists (select 1 from public.pay_claims pc where pc.kind = 'stay' and pc.ref_id = s.id and pc.status = 'confirmed')),
    'held', s.hold_until is not null and s.hold_until > now(), 'held_until', s.hold_until, 'cancelled', s.status = 'cancelled',
    'checking', exists (select 1 from public.pay_claims pc where pc.kind = 'stay' and pc.ref_id = s.id and pc.status = 'waiting'),
    'rejected', exists (select 1 from public.pay_claims pc where pc.kind = 'stay' and pc.ref_id = s.id and pc.status = 'rejected'),
    'room', r.name, 'from', s.check_in, 'to', s.check_out, 'price', s.room_price_thb, 'total', private.web_stay_total(s.id))
  from public.stays s join public.rooms r on r.id = s.room_id where s.id = p_stay and s.external_id like 'web:%'
$f$;

-- the desk: confirming a stay whose hold ran out needs the room to still be free; Not received gives the room back
create or replace function public.pay_claim_decide(p_id uuid, p_ok boolean) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare c public.pay_claims%rowtype; s public.stays;
begin
  if not private.is_desk() then raise exception 'Only front desk or a manager can confirm payments.'; end if;
  select * into c from public.pay_claims where id = p_id and status = 'waiting' for update;
  if c.id is null then raise exception 'That was already checked.'; end if;
  if c.kind = 'stay' then
    select * into s from public.stays where id = c.ref_id for update;
    if p_ok and s.status = 'cancelled' and exists (select 1 from public.stays x where x.room_id = s.room_id and x.id <> s.id and x.status not in ('cancelled','out')
         and x.check_in < s.check_out and x.check_out > s.check_in) then
      raise exception 'The 12 hour hold ran out and the room has been booked by someone else. Offer another room, or refund them.'; end if;
  end if;
  update public.pay_claims set status = case when p_ok then 'confirmed' else 'rejected' end, decided_by = private.my_staff_id(), decided_at = now() where id = p_id;
  if p_ok then
    if c.kind = 'stay' then
      -- a hold that ran out is brought back (the room is checked free above), with the extras they picked
      if s.status = 'cancelled' then update public.purchases set cancelled = false where for_stay = s.id and ordered_in_app; end if;
      update public.stays set hold_until = coalesce(hold_until, now()), status = 'booked' where id = c.ref_id;
    end if;
    perform public.stripe_record('claim:' || c.id, c.kind, c.ref_id, c.amount_thb, 'qr');
  elsif c.kind = 'stay' and s.hold_until is not null and coalesce(s.app_paid_thb,0) = 0 then
    update public.stays set status = 'cancelled', hold_until = null, notes = coalesce(notes,'') || ' PromptPay payment not received.' where id = s.id;
    update public.purchases set cancelled = true where for_stay = s.id and ordered_in_app;
  end if;
  return jsonb_build_object('ok', true);
end $f$;

-- the desk list shows when a stay's hold runs out (or has run out)
create or replace function public.pay_claims_list() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.is_desk() then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'customer', cu.name, 'customer_id', c.customer_id, 'kind', c.kind, 'amount', c.amount_thb, 'what', c.what, 'at', c.created_at,
      'held_until', case when c.kind = 'stay' then (select s.hold_until from public.stays s where s.id = c.ref_id) end,
      'expired', c.kind = 'stay' and exists (select 1 from public.stays s where s.id = c.ref_id and s.status = 'cancelled')) order by c.created_at), '[]'::jsonb)
    from public.pay_claims c left join public.customers cu on cu.id = c.customer_id
    where c.status = 'waiting');
end $f$;

-- the "Website booking" alert says how they paid
do $$ declare d text := pg_get_functiondef('public.stripe_record(text,text,uuid,integer,text)'::regprocedure); begin
  if position('by PromptPay' in d) = 0 then
    d := replace(d, $a$|| ' THB by card.'$a$, $b$|| ' THB ' || case when p_method = 'qr' then 'by PromptPay.' else 'by card.' end$b$);
    if position('by PromptPay' in d) = 0 then raise exception 'stripe_record patch did not apply'; end if;
    execute d;
  end if;
end $$;
