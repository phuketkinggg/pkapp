-- Website: add recovery (spa) to a private lesson order. The buyer picks a number of spa sessions, or a spa week or month.
-- web_pkg_orders.price_thb stays the total to pay (so card fees, emails, PromptPay checks keep working);
-- pkg_price_thb is the main package's own price, and extras holds the spa add-on, made into its own purchase when paid.

alter table public.web_pkg_orders add column if not exists pkg_price_thb integer;
alter table public.web_pkg_orders add column if not exists extras jsonb;

-- checks one recovery add-on: {package_id, qty}. Only spa-only packages sold to everyone; qty only for single visits.
create or replace function private.web_recovery_extra(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare k public.packages; q int;
begin
  if p is null or jsonb_typeof(p) <> 'object' or nullif(p->>'package_id','') is null then return null; end if;
  begin select * into k from public.packages where id = (p->>'package_id')::uuid; exception when others then raise exception 'Choose the recovery again.'; end;
  if k.id is null or not k.active or k.price_thb is null or k.price_thb < 1 or coalesce(k.audience,'all') <> 'all' or coalesce(k.covers,'{}') <> '{Spa}' then
    raise exception 'That recovery option is not available online. WhatsApp us and we will add it.'; end if;
  q := coalesce(nullif(p->>'qty','')::int, 1);
  if coalesce(k.visit_limit, 0) <> 1 then q := 1; end if;
  if q < 1 or q > 20 then raise exception 'Choose between 1 and 20 recovery sessions.'; end if;
  return jsonb_build_object('package_id', k.id, 'name', k.name, 'qty', q, 'price', k.price_thb * q,
    'label', case when q > 1 then 'Recovery: ' || q || ' spa sessions' else 'Recovery: ' || regexp_replace(k.name, '^Spa Access,\s*', '') end);
end $$;
revoke all on function private.web_recovery_extra(jsonb) from public, anon, authenticated;

-- order: add the recovery to the total
do $$ declare s text;
begin
  s := pg_get_functiondef('public.web_pkg_order(jsonb)'::regprocedure);
  if s not like '%web_recovery_extra%' then
    s := replace(s, $a$oid uuid; n int; pr jsonb;$a$, $a$oid uuid; n int; pr jsonb; ex jsonb; tot int;$a$);
    s := replace(s, $a$  insert into public.web_pkg_orders (package_id, package_name, price_thb, name, email, phone, start_on, note, private_req)
    values (k.id, k.name, k.price_thb, nm, em, nullif(ph,''), st, nullif(left(btrim(coalesce(p->>'note','')),300),''), pr) returning id into oid;
  return jsonb_build_object('id', oid, 'amount', k.price_thb, 'what', k.name, 'email', em, 'private', pr);$a$,
$a$  ex := private.web_recovery_extra(p->'recovery');
  if ex is not null and not ('Privates' = any (coalesce(k.covers,'{}'))) then raise exception 'Recovery can be added to privates here. For other packages, see Recovery and spa.'; end if;
  tot := k.price_thb + coalesce((ex->>'price')::int, 0);
  insert into public.web_pkg_orders (package_id, package_name, price_thb, pkg_price_thb, extras, name, email, phone, start_on, note, private_req)
    values (k.id, k.name || coalesce(' + ' || (ex->>'label'), ''), tot, k.price_thb, case when ex is not null then jsonb_build_array(ex) end,
            nm, em, nullif(ph,''), st, nullif(left(btrim(coalesce(p->>'note','')),300),''), pr) returning id into oid;
  return jsonb_build_object('id', oid, 'amount', tot, 'what', k.name || coalesce(' + ' || (ex->>'label'), ''), 'email', em, 'private', pr);$a$);
    if s not like '%web_recovery_extra%' then raise exception 'web_pkg_order patch did not apply'; end if;
    execute s;
  end if;
end $$;

-- paid: the main package at its own price, then the recovery as its own purchase
do $$ declare s text;
begin
  s := pg_get_functiondef('private.web_pkg_paid(uuid,text,integer)'::regprocedure);
  if s not like '%o.extras%' then
    s := replace(s, $a$k public.packages; cid uuid; pid uuid;$a$, $a$k public.packages; k2 public.packages; e jsonb; xid uuid; cid uuid; pid uuid;$a$);
    s := replace(s, $a$    values (cid, k.id, k.name, o.price_thb, 'standard', true, o.price_thb, 'card', t,$a$,
                    $a$    values (cid, k.id, k.name, coalesce(o.pkg_price_thb, o.price_thb), 'standard', true, coalesce(o.pkg_price_thb, o.price_thb), 'card', t,$a$);
    s := replace(s, $a$  if p_amount > o.price_thb then$a$,
$a$  for e in select * from jsonb_array_elements(coalesce(o.extras, '[]'::jsonb)) loop
    select * into k2 from public.packages where id = (e->>'package_id')::uuid;
    if k2.id is null then continue; end if;
    insert into public.purchases (customer_id, package_id, package_name, price_thb, price_group, paid, paid_thb, method, purchased_on, covers, times,
        visit_limit, visits_left, per_week_limit, duration_days, start_by, starts_on, expires_on)
      values (cid, k2.id, k2.name || case when (e->>'qty')::int > 1 then ' x ' || (e->>'qty') else '' end, (e->>'price')::int, 'standard', true, (e->>'price')::int, 'card', t,
        coalesce(k2.covers,'{}'), k2.times,
        case when k2.visit_limit is not null then k2.visit_limit * (e->>'qty')::int end, case when k2.visit_limit is not null then k2.visit_limit * (e->>'qty')::int end,
        k2.per_week_limit, case when k2.visit_limit = 1 and (e->>'qty')::int > 1 then 180 else k2.duration_days end,
        case when k2.clock <> 'purchase' and k2.start_within_days is not null then t + greatest(k2.start_within_days, 180) end,
        null, null)
      returning id into xid;
    update public.payments set stripe_session = p_session, method = meth, note = case when qr then 'PromptPay, website order (recovery)' else 'Paid on the website (recovery)' end
      where purchase_id = xid and stripe_session is null;
  end loop;
  if p_amount > o.price_thb then$a$);
    if s not like '%o.extras%' or s not like '%coalesce(o.pkg_price_thb, o.price_thb)%' then raise exception 'web_pkg_paid patch did not apply'; end if;
    execute s;
  end if;
end $$;
