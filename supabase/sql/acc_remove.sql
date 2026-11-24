-- Accounts, Money in: open any line to see the single payments in it, and remove a payment taken by mistake (feature acc_remove).
-- Removing voids the payment (it stays in the records, marked removed, with who, when and why) so it leaves Money in.

create or replace function public.acc_payment_get(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare p public.payments;
begin
  if coalesce(private.staff_role(), '') <> 'manager' or not private.can('money') then raise exception 'Only a manager can see this.'; end if;
  select * into p from public.payments where id = p_id;
  if p.id is null then raise exception 'Payment not found.'; end if;
  return jsonb_build_object('id', p.id, 'day', p.day, 'at', p.at, 'amount', p.amount_thb, 'method', p.method, 'voided', p.voided, 'note', p.note,
    'customer', (select c.name from public.customers c where c.id = p.customer_id),
    'by', (select s.name from public.staff s where s.id = p.by_staff),
    'what', coalesce(
      (select k.package_name from public.purchases k where k.id = p.purchase_id),
      (select 'Private ' || to_char(x.date, 'DD Mon') || coalesce(', ' || nullif(x.guest_name, ''), '') || case when x.status = 'cancelled' then ' (cancelled)' else '' end from public.privates x where x.id = p.private_id),
      (select 'Room bill, ' || r.name from public.stays s join public.rooms r on r.id = s.room_id where s.id = p.stay_id),
      'Payment'),
    'linked', case when p.purchase_id is not null then 'package' when p.private_id is not null then 'private' when p.stay_id is not null then 'stay' end);
end $f$;

create or replace function public.acc_payment_remove(p_id uuid, p_reason text) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare p public.payments; why text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if not private.feature('acc_remove', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if coalesce(private.staff_role(), '') <> 'manager' or not private.can('money') then raise exception 'Only a manager can remove money from the accounts.'; end if;
  if why = '' then raise exception 'Write why it is removed.'; end if;
  select * into p from public.payments where id = p_id for update;
  if p.id is null then raise exception 'Payment not found.'; end if;
  if p.voided then return jsonb_build_object('ok', true, 'already', true); end if;
  if p.stripe_session is not null then raise exception 'This was paid online by card. Refund it from the customer or booking instead, so the card gets the money back.'; end if;
  update public.payments set voided = true,
    note = left(coalesce(nullif(note, '') || '. ', '') || 'Removed in Accounts by ' || coalesce((select name from public.staff where id = private.my_staff_id()), 'a manager')
      || ' on ' || to_char(private.bkk_today(), 'DD Mon YYYY') || ': ' || why, 1000)
  where id = p_id;
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.acc_payment_get(uuid), public.acc_payment_remove(uuid, text) from public, anon;
grant execute on function public.acc_payment_get(uuid), public.acc_payment_remove(uuid, text) to authenticated;

notify pgrst, 'reload schema';
