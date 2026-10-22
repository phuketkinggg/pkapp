-- Weekly room bills: close the bill up to a date (the guest pays the nights and charges before that date), a new bill starts from there.
-- Each closed part is kept on the stay in bill_periods. The money goes into payments (room and charges) and the till items in it count
-- in the accounts on the day that part was paid. Settling the stay at the end takes only what is left.

alter table public.stays add column if not exists bill_periods jsonb not null default '[]'::jsonb;
grant select (bill_periods) on public.stays to authenticated;

create or replace function public.stay_close_period(p_stay uuid, p_upto date, p_method text) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s public.stays; last_upto date; start_d date; n_all int; n int; room int; ch_all int; till int; credit_pool int; credit_used int; credit int; pay int; pid uuid; per jsonb;
  room_before int; m text := coalesce(nullif(p_method,''),'cash');
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  select * into s from public.stays where id = p_stay for update;
  if not found then raise exception 'Stay not found.'; end if;
  if s.settled then raise exception 'This bill is already settled.'; end if;
  if m not in ('cash','card','transfer','qr','stripe') then raise exception 'Choose how they paid.'; end if;
  select max((x->>'upto')::date) into last_upto from jsonb_array_elements(s.bill_periods) x;
  start_d := coalesce(last_upto, s.check_in);
  if p_upto is null or p_upto <= start_d then raise exception 'Pick a date after %.', to_char(start_d, 'DD Mon'); end if;
  if p_upto > s.check_out then raise exception 'Pick a date on or before check out, %.', to_char(s.check_out, 'DD Mon'); end if;
  n_all := greatest(1, s.check_out - s.check_in);
  n := p_upto - start_d;
  select coalesce(sum((x->>'room')::int),0) into room_before from jsonb_array_elements(s.bill_periods) x;
  room := case when s.room_price_thb is null then 0
               when p_upto = s.check_out then greatest(0, s.room_price_thb - room_before)
               else round(s.room_price_thb::numeric * n / n_all)::int end;
  select coalesce(sum(amount_thb),0)::int, coalesce(sum(amount_thb) filter (where order_id is not null),0)::int into ch_all, till
    from public.room_charges where stay_id = s.id and not coalesce(voided,false) and day >= start_d and day < p_upto
      and not (private_id is not null and coalesce(amount_thb,0) = 0);
  -- money already paid ahead (website deposit, app payments) is used up first
  select coalesce(s.room_paid_thb,0) + coalesce((select sum(amount_thb) from public.payments where stay_id = s.id and not voided and coalesce(note,'') <> 'Room bill'
           and id not in (select (x->>'payment_id')::uuid from jsonb_array_elements(s.bill_periods) x where x->>'payment_id' is not null)),0)::int into credit_pool;
  select coalesce(sum((x->>'credit')::int),0) into credit_used from jsonb_array_elements(s.bill_periods) x;
  credit := least(greatest(0, credit_pool - credit_used), room + ch_all);
  -- the till part counts in the accounts through the till sale itself, so the payment is the room and the other charges
  pay := greatest(0, room + (ch_all - till) - credit);
  pid := private.pay_insert(s.customer_id, null, null, s.id, pay, m, private.bkk_today(), 'Room bill to ' || to_char(p_upto, 'DD Mon YYYY'));
  per := jsonb_build_object('id', gen_random_uuid(), 'from', start_d, 'upto', p_upto, 'nights', n, 'room', room, 'charges', ch_all, 'till', till, 'credit', credit,
    'total', room + ch_all - credit, 'method', m, 'paid_on', private.bkk_today(), 'payment_id', pid, 'by', (select name from public.staff where id = private.my_staff_id()), 'at', now());
  update public.stays set bill_periods = bill_periods || jsonb_build_array(per) where id = s.id;
  return per;
end $$;

-- a manager can undo the last closed part (its payment is voided)
create or replace function public.stay_undo_period(p_stay uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare s public.stays; lastp jsonb;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can undo this.'; end if;
  select * into s from public.stays where id = p_stay for update;
  if s.settled then raise exception 'Reopen the bill first.'; end if;
  select x into lastp from jsonb_array_elements(s.bill_periods) x order by (x->>'upto')::date desc limit 1;
  if lastp is null then raise exception 'Nothing to undo.'; end if;
  if lastp->>'payment_id' is not null then update public.payments set voided = true where id = (lastp->>'payment_id')::uuid; end if;
  update public.stays set bill_periods = (select coalesce(jsonb_agg(x order by (x->>'upto')::date), '[]'::jsonb) from jsonb_array_elements(s.bill_periods) x where x->>'id' <> lastp->>'id')
   where id = s.id;
end $$;

revoke all on function public.stay_close_period(uuid,date,text), public.stay_undo_period(uuid) from public, anon;
grant execute on function public.stay_close_period(uuid,date,text), public.stay_undo_period(uuid) to authenticated;

-- reopening a settled bill only takes back the final payment, not the weekly ones
create or replace function private.stay_settled() returns trigger language plpgsql security definer set search_path to '' as $function$
declare due integer;
begin
  if new.settled and not coalesce(old.settled,false) then
    due := private.stay_due(new.id) - private.stay_till_total(new.id);
    if due > 0 then perform private.pay_insert(new.customer_id, null, null, new.id, due, coalesce(new.settled_method,'cash'), coalesce(new.settled_on, private.bkk_today()), 'Room bill'); end if;
  elsif not new.settled and coalesce(old.settled,false) then
    update public.payments set voided = true where stay_id = new.id and not voided and stripe_session is null
      and id not in (select (x->>'payment_id')::uuid from jsonb_array_elements(new.bill_periods) x where x->>'payment_id' is not null);
  end if;
  return null;
end $function$;

-- accounts: till sales on a room bill count on the day their part of the bill was paid (weekly), or when the stay is settled
do $$ declare d text := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure); begin
  if position('bill_periods' in d) = 0 then
    d := replace(d, $a$  select s.settled_on,
    case when lower(coalesce(l.name,'')) like '%cafe%' and lower(coalesce(c.name,'')) <> 'spa' then 'Pangea Resort' else 'Phuket King Gym' end,
    case when lower(coalesce(c.name,'')) = 'spa' then 'Spa' when lower(coalesce(l.name,'')) like '%cafe%' then 'Pangea Cafe' else 'Gym shop' end,
    'in', coalesce(c.name,'Shop')||': '||i.name, 'Sales', coalesce(s.settled_method,'room'),$a$,
    $b$  select z.cd,
    case when lower(coalesce(l.name,'')) like '%cafe%' and lower(coalesce(c.name,'')) <> 'spa' then 'Pangea Resort' else 'Phuket King Gym' end,
    case when lower(coalesce(c.name,'')) = 'spa' then 'Spa' when lower(coalesce(l.name,'')) like '%cafe%' then 'Pangea Cafe' else 'Gym shop' end,
    'in', coalesce(c.name,'Shop')||': '||i.name, 'Sales', coalesce(z.cm,'room'),$b$);
    d := replace(d, $a$  from public.shop_orders o join public.stays s on s.id = o.stay_id and s.settled and s.settled_on >= date '2026-10-20'$a$,
    $b$  from public.shop_orders o join public.stays s on s.id = o.stay_id
    cross join lateral (select coalesce(pp.paid_on, case when s.settled then s.settled_on end) cd, coalesce(pp.method, s.settled_method) cm
      from (select null::int) dummy left join lateral (select (x->>'paid_on')::date paid_on, x->>'method' method from jsonb_array_elements(s.bill_periods) x
        where coalesce((select min(rc.day) from public.room_charges rc where rc.order_id = o.id), (o.created_at at time zone 'Asia/Bangkok')::date) < (x->>'upto')::date
        order by (x->>'upto')::date limit 1) pp on true) z$b$);
    d := replace(d, $a$  where o.status = 'room' and s.settled_on between p_from and p_to$a$,
      $b$  where o.status = 'room' and z.cd >= date '2026-10-20' and z.cd between p_from and p_to$b$);
    if position('z.cd between p_from and p_to' in d) = 0 or position('coalesce(z.cm' in d) = 0 or position('cross join lateral (select coalesce(pp.paid_on' in d) = 0 then
      raise exception 'acc_lines patch did not apply'; end if;
    execute d;
  end if;
end $$;
