-- Cancel and refund a stay (feature stay_refund): money back for the room and any add-ons in one go.
-- Each amount goes in as money out (a minus payment) on the day of the refund, in the same department as the money that came in,
-- so Accounts corrects itself. Add-ons are refunded like Refund on a package (they stop working). The stay can be cancelled too.
-- p_dry: only check the PIN and the amounts (the booking page refund through Stripe checks first, then refunds the card, then records it).
-- New functions only (nothing existing is changed). Needs private.pay_insert, private.manager_pin and private.refundable.
create or replace function private.stay_room_refundable(p_stay uuid) returns integer
language sql stable security definer set search_path to '' as $q$
  -- room money taken on this stay (deposits, paid ahead, the settled bill), less extras charged to a settled bill (those refund on the add-on)
  select greatest(0,
    coalesce((select sum(amount_thb) from public.payments where stay_id = p_stay and purchase_id is null and private_id is null and not voided and not coalesce(is_fee, false)), 0)
    - coalesce((select sum(rc.amount_thb) from public.room_charges rc join public.stays s on s.id = rc.stay_id
                where rc.stay_id = p_stay and s.settled and not rc.voided and (rc.purchase_id is not null or rc.private_id is not null)), 0))::int
$q$;

create or replace function public.stay_refund_info(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $q$
declare s public.stays%rowtype;
begin
  if not private.is_desk() then raise exception 'Not allowed.'; end if;
  select * into s from public.stays where id = p_stay; if s.id is null then raise exception 'That stay is not there any more.'; end if;
  return jsonb_build_object(
    'room', private.stay_room_refundable(p_stay),
    'status', s.status,
    'stripe', (select stripe_session from public.payments p where not p.voided and p.amount_thb > 0 and p.stripe_session is not null
                 and (p.stay_id = p_stay or p.purchase_id in (select id from public.purchases where for_stay = p_stay or stay_id = p_stay))
               order by p.at desc limit 1),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.package_name, 'paid', private.refundable(k.id, null)) order by k.created_at)
       from public.purchases k where (k.for_stay = p_stay or k.stay_id = p_stay) and k.refunded_at is null
         and k.package_name <> 'Stay: group Muay Thai included' and private.refundable(k.id, null) > 0), '[]'::jsonb));
end $q$;

create or replace function public.refund_stay(p_stay uuid, p_room integer, p_extras jsonb, p_method text, p_pin text, p_reason text, p_cancel boolean, p_dry boolean default false, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $q$
declare s public.stays%rowtype; who uuid; why text := btrim(coalesce(p_reason,'')); mx integer; room integer := coalesce(p_room, 0);
  x jsonb; k public.purchases%rowtype; a integer; total integer := 0; meth text := coalesce(nullif(p_method,''),'cash'); cn text; tag text;
begin
  if not private.is_desk() then raise exception 'Not allowed.'; end if;
  who := private.manager_pin(p_pin);
  if why = '' then raise exception 'Say why it is refunded.'; end if;
  select * into s from public.stays where id = p_stay for update; if s.id is null then raise exception 'That stay is not there any more.'; end if;
  mx := private.stay_room_refundable(p_stay);
  if room < 0 or room > mx then raise exception 'You can give back up to % THB on the room.', mx; end if;
  -- check every add-on first
  for x in select * from jsonb_array_elements(coalesce(p_extras, '[]'::jsonb)) loop
    select * into k from public.purchases where id = (x->>'id')::uuid for update;
    if k.id is null or not (k.for_stay = p_stay or k.stay_id = p_stay) then raise exception 'That add-on is not on this stay.'; end if;
    if k.refunded_at is not null then raise exception '% was already refunded.', k.package_name; end if;
    a := coalesce((x->>'amount')::int, 0); mx := greatest(private.refundable(k.id, null), 0);
    if a < 0 or a > mx then raise exception 'You can give back up to % THB on %.', mx, k.package_name; end if;
    total := total + a;
  end loop;
  total := total + room;
  if total = 0 and not coalesce(p_cancel, false) then raise exception 'Nothing to refund. Type an amount, or tick Cancel the stay.'; end if;
  if p_dry then return jsonb_build_object('ok', true, 'total', total); end if;

  tag := 'Refund: ' || why || coalesce(' (' || nullif(btrim(coalesce(p_note,'')), '') || ')', '');
  if room > 0 then perform private.pay_insert(s.customer_id, null, null, p_stay, -room, meth, private.bkk_today(), tag); end if;
  for x in select * from jsonb_array_elements(coalesce(p_extras, '[]'::jsonb)) loop
    select * into k from public.purchases where id = (x->>'id')::uuid; a := coalesce((x->>'amount')::int, 0);
    if a > 0 then perform private.pay_insert(k.customer_id, k.id, null, null, -a, meth, private.bkk_today(), tag); end if;
    update public.room_charges rc set amount_thb = 0, voided = true, void_note = 'Refunded: ' || why
      where rc.purchase_id = k.id and not rc.voided and not exists (select 1 from public.stays t where t.id = rc.stay_id and t.settled);
    update public.privates set status = 'cancelled' where purchase_id = k.id and date >= private.bkk_today() and status in ('confirmed','requested');
    update public.purchases set cancelled = true, refunded_at = now(), refund_thb = a, refund_reason = why, refunded_by = who where id = k.id;
  end loop;
  if coalesce(p_cancel, false) and s.status <> 'cancelled' then
    update public.stays set status = 'cancelled', hold_until = null,
      notes = btrim(coalesce(notes, '') || E'\n' || 'Cancelled ' || to_char(private.bkk_today(), 'DD Mon YYYY') || ': ' || why || case when total > 0 then ', refunded ' || to_char(total, 'FM999,999,990') || ' THB' else '' end)
    where id = p_stay;
  end if;
  select name into cn from public.customers where id = s.customer_id;
  insert into public.notices (kind, customer_id, ref_id, title, detail)
  values ('refund', s.customer_id, p_stay, 'Refund: stay' || case when coalesce(p_cancel,false) then ' cancelled' else '' end || ', ' || coalesce(cn, 'a guest'),
          to_char(total, 'FM999,999,990') || ' THB back. ' || why);
  return jsonb_build_object('refunded', total);
end $q$;

revoke all on function public.refund_stay(uuid,integer,jsonb,text,text,text,boolean,boolean,text) from public, anon;
grant execute on function public.refund_stay(uuid,integer,jsonb,text,text,text,boolean,boolean,text) to authenticated;
revoke all on function public.stay_refund_info(uuid) from public, anon;
grant execute on function public.stay_refund_info(uuid) to authenticated;
revoke all on function private.stay_room_refundable(uuid) from public, anon, authenticated;
