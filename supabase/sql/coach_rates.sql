-- Coaches with their own private rate (for example Kru Pot, 1,300 THB, keeps 100%).
-- staff.private_rate_thb: their price for a private, paid direct (no pack). Their share stays staff.commission_pct (set 100 for no gym commission).
-- On a private pack (bought at the normal price) they are only bookable with a top up: privates.extra_thb = their rate minus the pack session value.
-- The top up is paid at the desk (or online with the pack) and counts in full toward the coach's share like the rest of the private.

alter table public.staff add column if not exists private_rate_thb int check (private_rate_thb between 1 and 100000);
grant select (private_rate_thb), insert (private_rate_thb), update (private_rate_thb) on public.staff to authenticated;

alter table public.privates add column if not exists extra_thb int not null default 0 check (extra_thb >= 0);
alter table public.privates add column if not exists extra_paid boolean not null default false;
alter table public.privates add column if not exists extra_method text;

-- the rate of the coach on a private (the coach, or while requested the one they asked for)
create or replace function private.coach_rate(p_coach uuid) returns int language sql stable security definer set search_path to '' as $$
  select private_rate_thb from public.staff where id = p_coach
$$;

-- before insert or update (after privates_guard has priced a pack session): set the top up, or the coach's own price
create or replace function private.private_rate_trg() returns trigger language plpgsql security definer set search_path to '' as $$
declare rate int := private.coach_rate(coalesce(new.coach_id, new.preferred_coach_id)); direct boolean;
begin
  if new.status = 'cancelled' then return new; end if;
  if tg_op = 'UPDATE' and new.extra_paid and old.extra_paid then return new; end if;  -- a paid top up never changes
  if tg_op = 'UPDATE' and old.coach_id is not distinct from new.coach_id and old.preferred_coach_id is not distinct from new.preferred_coach_id
     and old.purchase_id is not distinct from new.purchase_id and old.price_thb is not distinct from new.price_thb then return new; end if;
  if new.purchase_id is not null then
    new.extra_thb := case when rate is not null then greatest(rate - coalesce(new.price_thb, 0), 0) else 0 end;
    if new.extra_thb = 0 then new.extra_paid := false; new.extra_method := null; end if;
  else
    new.extra_thb := 0; new.extra_paid := false; new.extra_method := null;
    -- paid direct (no agency): the coach's own price
    direct := new.source_id is null or exists (select 1 from public.booking_sources b where b.id = new.source_id and lower(b.name) = 'direct');
    if rate is not null and direct and not coalesce(new.paid, false) and coalesce(new.fee_thb, 0) = 0 and coalesce(new.tax_thb, 0) = 0 then new.price_thb := rate; end if;
  end if;
  return new;
end $$;
drop trigger if exists privates_rate on public.privates;
create trigger privates_rate before insert or update on public.privates for each row execute function private.private_rate_trg();

-- after: a paid top up becomes a payment (and is voided if unticked)
create or replace function private.private_extra_pay_trg() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.extra_paid and new.extra_thb > 0 and (tg_op = 'INSERT' or not old.extra_paid) then
    perform private.pay_insert(new.customer_id, null, new.id, null, new.extra_thb, coalesce(new.extra_method, 'cash'), least(new.date, private.bkk_today()), 'Top up for the coach''s own rate');
  elsif tg_op = 'UPDATE' and old.extra_paid and not new.extra_paid and new.purchase_id is not null then
    update public.payments set voided = true where private_id = new.id and not voided and purchase_id is null;
  end if;
  return null;
end $$;
drop trigger if exists privates_extra_pay on public.privates;
create trigger privates_extra_pay after insert or update of extra_paid, extra_thb on public.privates for each row execute function private.private_extra_pay_trg();

-- the desk takes the top up
create or replace function public.private_extra_paid(p_id uuid, p_method text)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin','front_desk') then raise exception 'Only the front desk takes payment.'; end if;
  if p_method not in ('cash','card','transfer','qr','room') then raise exception 'Choose how they paid.'; end if;
  update public.privates set extra_paid = true, extra_method = p_method where id = p_id and extra_thb > 0 and not extra_paid and status <> 'cancelled';
  if not found then raise exception 'Nothing to pay on that private.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.private_extra_paid(uuid, text) from public, anon;
grant execute on function public.private_extra_paid(uuid, text) to authenticated;
revoke all on function private.coach_rate(uuid) from public, anon, authenticated;

-- commission and the coach's own screen count the top up as part of the private
do $$ declare s text;
begin
  s := pg_get_functiondef('public.commission_pay(uuid,date,date,text)'::regprocedure);
  if s not like '%extra_thb%' then
    s := replace(s, '(coalesce(p.price_thb,0) - p.fee_thb - p.tax_thb)', '(coalesce(p.price_thb,0) - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0))');
    if s not like '%extra_thb%' then raise exception 'commission_pay patch did not apply'; end if;
    execute s;
  end if;
  s := pg_get_functiondef('public.coach_home()'::regprocedure);
  if s not like '%extra_thb%' then
    s := replace(s, '''share_thb'', round((p.price_thb - p.fee_thb - p.tax_thb) * p.coach_pct / 100.0)', '''share_thb'', round((p.price_thb - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0)) * p.coach_pct / 100.0)');
    if s not like '%extra_thb%' then raise exception 'coach_home patch did not apply'; end if;
    execute s;
  end if;
  -- the coach booking a private themselves: their own price
  s := pg_get_functiondef('public.coach_book_private(uuid,time,text,text)'::regprocedure);
  if s not like '%coach_rate%' then
    s := replace(s, '''share'', round(v_price * coalesce(v_pct, 50) / 100.0)', '''share'', round((select x.price_thb + x.extra_thb from public.privates x where x.id = v_id) * coalesce(v_pct, 50) / 100.0), ''extra'', (select x.extra_thb from public.privates x where x.id = v_id), ''rate'', private.coach_rate(me)');
    if s not like '%coach_rate%' then raise exception 'coach_book_private patch did not apply'; end if;
    execute s;
  end if;
  -- online booking shows each coach's own rate
  s := pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure);
  if s not like '%private_rate_thb%' then
    s := replace(s, '''photo'', s.photo_url)', '''photo'', s.photo_url, ''rate'', (select x.private_rate_thb from public.staff x where x.id = s.id))');
    if s not like '%private_rate_thb%' then raise exception 'private_book_slots patch did not apply'; end if;
    execute s;
  end if;
end $$;

-- website: a private pack bought with the first session booked with a coach who has their own rate adds the top up to the order
do $$ declare s text;
begin
  s := pg_get_functiondef('public.web_pkg_order(jsonb)'::regprocedure);
  if s not like '%coach_rate%' then
    s := replace(s, $a$  tot := k.price_thb + coalesce((ex->>'price')::int, 0);$a$,
$a$  tot := k.price_thb + coalesce((ex->>'price')::int, 0);
  -- a coach with their own rate: the first session needs a top up (their rate minus one pack session)
  if pr is not null and private.coach_rate((pr->>'coach')::uuid) is not null and coalesce(k.visit_limit, 0) > 0 then
    ex := jsonb_build_object('coach_extra', greatest(private.coach_rate((pr->>'coach')::uuid) - round(k.price_thb::numeric / k.visit_limit)::int, 0),
      'price', coalesce((ex->>'price')::int, 0), 'label', ex->>'label', 'package_id', ex->>'package_id', 'qty', ex->>'qty', 'name', ex->>'name');
    tot := k.price_thb + coalesce((ex->>'price')::int, 0) + (ex->>'coach_extra')::int;
  end if;$a$);
    s := replace(s, $a$case when ex is not null then jsonb_build_array(ex) end,$a$, $a$case when ex is not null and ex->>'package_id' is not null then jsonb_build_array(ex - 'coach_extra') end,$a$);
    s := replace(s, $a$values (k.id, k.name || coalesce(' + ' || (ex->>'label'), ''), tot,$a$, $a$values (k.id, k.name || coalesce(' + ' || (ex->>'label'), '') || case when coalesce((ex->>'coach_extra')::int,0) > 0 then ' + coach top up' else '' end, tot,$a$);
    if s not like '%coach_rate%' then raise exception 'web_pkg_order patch did not apply'; end if;
    execute s;
  end if;
  s := pg_get_functiondef('private.web_pkg_private(uuid)'::regprocedure);
  if s not like '%extra_paid%' then
    s := replace(s, $a$    perform private.private_request_notice(v_id,$a$, $a$    if o.package_name like '% + coach top up' then
      update public.privates set extra_paid = true, extra_method = case when o.stripe_session like 'claim:%' then 'qr' else 'card' end where id = v_id and extra_thb > 0;
    end if;
    perform private.private_request_notice(v_id,$a$);
    if s not like '%extra_paid%' then raise exception 'web_pkg_private patch did not apply'; end if;
    execute s;
  end if;
end $$;

-- the customer app shows the top up on their private
do $$ declare s text;
begin
  s := pg_get_functiondef('public.customer_home()'::regprocedure);
  if s not like '%extra_paid%' then
    s := replace(s, $a$'price', p.price_thb, 'decline'$a$, $a$'price', p.price_thb, 'extra', p.extra_thb, 'extra_paid', p.extra_paid, 'decline'$a$);
    if s not like '%extra_paid%' then raise exception 'customer_home patch did not apply'; end if;
    execute s;
  end if;
end $$;
