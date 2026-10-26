-- Affiliates: choose what each affiliate earns on, and the % for each: room stays, single packages (tick a whole group or
-- one by one), online courses, and anything added later. No rules (null) means the old way: their one % on everything.
-- rules = {"stays": 10 | null, "packages": {"<package id>": 10, ...}, "courses": {"<course id>": 15, ...}, "other": 5 | null}
-- A product with no % is not counted: a booking or sale of it is not tagged to them.

alter table public.affiliates add column if not exists rules jsonb;
alter table public.web_pkg_orders add column if not exists affiliate_pct numeric;

-- the % for one thing: 'stay', a package id, or a course id; null = not counted
create or replace function private.aff_pct(a public.affiliates, p_kind text, p_ref uuid) returns numeric language sql stable set search_path to '' as $$
  select case when a.rules is null then a.pct
    when p_kind = 'stay' then nullif(a.rules->>'stays','')::numeric
    when p_kind = 'package' then coalesce(nullif(a.rules->'packages'->>p_ref::text,'')::numeric, nullif(a.rules->>'other','')::numeric)
    when p_kind = 'course' then coalesce(nullif(a.rules->'courses'->>p_ref::text,'')::numeric, nullif(a.rules->>'other','')::numeric) end
$$;

-- stays: the % from the rules; a stay the affiliate does not earn on is not tagged
create or replace function private.stay_affiliate_pct() returns trigger language plpgsql set search_path to '' as $$
declare a public.affiliates;
begin
  if new.affiliate_id is null then new.affiliate_pct := null; return new; end if;
  if tg_op = 'INSERT' or new.affiliate_id is distinct from old.affiliate_id or new.affiliate_pct is null then
    select * into a from public.affiliates where id = new.affiliate_id;
    if tg_table_name = 'purchases' then new.affiliate_pct := private.aff_pct(a, 'package', new.package_id);
    else new.affiliate_pct := private.aff_pct(a, 'stay', null); end if;
    if new.affiliate_pct is null then new.affiliate_id := null; end if;
  end if;
  return new;
end $$;

create or replace function public.affiliate_tag_stay(p_stay uuid, p_code text) returns boolean language plpgsql security definer set search_path to '' as $$
declare a public.affiliates;
begin
  select * into a from public.affiliates where code = lower(trim(coalesce(p_code,''))) and active;
  if a.id is null or private.aff_pct(a, 'stay', null) is null then return false; end if;
  update public.stays set affiliate_id = a.id where id = p_stay and affiliate_id is null;
  return found;
end $$;

-- website orders: a course on its own keeps its % on the order (there is no package); a package gets it when it is made
create or replace function public.affiliate_tag_order(p_order uuid, p_code text) returns boolean language plpgsql security definer set search_path to '' as $$
declare a public.affiliates; o public.web_pkg_orders;
begin
  select * into a from public.affiliates where code = lower(trim(coalesce(p_code,''))) and active;
  if a.id is null then return false; end if;
  select * into o from public.web_pkg_orders where id = p_order;
  if o.id is null or o.affiliate_id is not null then return false; end if;
  if o.package_id is null and o.course_id is not null then
    if private.aff_pct(a, 'course', o.course_id) is null then return false; end if;
    update public.web_pkg_orders set affiliate_id = a.id, affiliate_pct = private.aff_pct(a, 'course', o.course_id) where id = p_order;
    return true;
  end if;
  if o.package_id is not null and private.aff_pct(a, 'package', o.package_id) is null then return false; end if;
  update public.web_pkg_orders set affiliate_id = a.id where id = p_order;
  if o.purchase_id is not null then update public.purchases set affiliate_id = a.id where id = o.purchase_id and affiliate_id is null; end if;
  return true;
end $$;
revoke all on function public.affiliate_tag_order(uuid, text) from public, anon, authenticated;
grant execute on function public.affiliate_tag_order(uuid, text) to service_role;

-- manager: save the rules (null = one % on everything)
create or replace function public.affiliate_rules_set(p_id uuid, p_rules jsonb) returns void language plpgsql security definer set search_path to '' as $$
declare r jsonb := null; k text; v jsonb; pk jsonb := '{}'; cr jsonb := '{}';
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change affiliates.'; end if;
  if p_rules is not null and jsonb_typeof(p_rules) = 'object' then
    for k, v in select * from jsonb_each(coalesce(p_rules->'packages','{}')) loop
      if v::text ~ '^"?[0-9]+(\.[0-9]+)?"?$' and (v#>>'{}')::numeric between 0 and 50 then pk := pk || jsonb_build_object(k, (v#>>'{}')::numeric); end if; end loop;
    for k, v in select * from jsonb_each(coalesce(p_rules->'courses','{}')) loop
      if v::text ~ '^"?[0-9]+(\.[0-9]+)?"?$' and (v#>>'{}')::numeric between 0 and 50 then cr := cr || jsonb_build_object(k, (v#>>'{}')::numeric); end if; end loop;
    r := jsonb_build_object('stays', case when (p_rules->>'stays') ~ '^[0-9]+(\.[0-9]+)?$' and (p_rules->>'stays')::numeric <= 50 then (p_rules->>'stays')::numeric end,
      'packages', pk, 'courses', cr,
      'other', case when (p_rules->>'other') ~ '^[0-9]+(\.[0-9]+)?$' and (p_rules->>'other')::numeric <= 50 then (p_rules->>'other')::numeric end);
  end if;
  update public.affiliates set rules = r where id = p_id;
  if not found then raise exception 'Not found.'; end if;
end $$;
revoke all on function public.affiliate_rules_set(uuid, jsonb) from public, anon;
grant execute on function public.affiliate_rules_set(uuid, jsonb) to authenticated;

create or replace function private.aff_ocommission(o public.web_pkg_orders) returns integer language sql immutable set search_path to '' as $$
  select case when o.affiliate_id is null or o.paid_at is null then 0 else round(coalesce(o.price_thb,0) * coalesce(o.affiliate_pct,0) / 100)::int end
$$;

-- the affiliate's card: rules, stays, packages and courses
create or replace function private.aff_row(a public.affiliates, p_full boolean) returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'email', a.email, 'phone', a.phone, 'customer_id', a.customer_id,
    'pct', a.pct, 'active', a.active, 'note', a.note, 'rules', a.rules,
    'earned', coalesce((select sum(private.aff_commission(s)) from public.stays s where s.affiliate_id = a.id and private.aff_state(s) = 'earned'),0)
            + coalesce((select sum(private.aff_pcommission(k)) from public.purchases k where k.affiliate_id = a.id and private.aff_pstate(k) = 'earned'),0)
            + coalesce((select sum(private.aff_ocommission(o)) from public.web_pkg_orders o where o.affiliate_id = a.id and o.package_id is null and o.course_id is not null and o.paid_at is not null),0),
    'coming', coalesce((select sum(private.aff_commission(s)) from public.stays s where s.affiliate_id = a.id and private.aff_state(s) = 'coming'),0)
            + coalesce((select sum(private.aff_pcommission(k)) from public.purchases k where k.affiliate_id = a.id and private.aff_pstate(k) = 'coming'),0),
    'paid', coalesce((select sum(amount_thb) from public.affiliate_payouts where affiliate_id = a.id and not voided),0),
    'stays', coalesce((select jsonb_agg(jsonb_build_object('id', s.id,
        'guest', case when p_full then c.name else split_part(coalesce(c.name,'Guest'),' ',1) end,
        'room', case when p_full then r.name end, 'from', s.check_in, 'to', s.check_out,
        'price', case when p_full then s.room_price_thb end, 'pct', s.affiliate_pct,
        'commission', private.aff_commission(s), 'state', private.aff_state(s)) order by s.check_in desc)
      from public.stays s left join public.customers c on c.id = s.customer_id left join public.rooms r on r.id = s.room_id
      where s.affiliate_id = a.id), '[]'::jsonb),
    'sales', coalesce((select jsonb_agg(x order by x->>'on' desc) from (
        select jsonb_build_object('id', k.id, 'guest', case when p_full then c.name else split_part(coalesce(c.name,'Guest'),' ',1) end,
          'what', k.package_name, 'on', k.purchased_on, 'price', case when p_full then coalesce(k.price_thb,0) - coalesce(k.fee_thb,0) - coalesce(k.tax_thb,0) end, 'pct', k.affiliate_pct,
          'commission', private.aff_pcommission(k), 'state', private.aff_pstate(k)) x
        from public.purchases k left join public.customers c on c.id = k.customer_id where k.affiliate_id = a.id
        union all
        select jsonb_build_object('id', o.id, 'guest', case when p_full then o.name else split_part(coalesce(o.name,'Guest'),' ',1) end,
          'what', coalesce((select title from public.courses where id = o.course_id), 'Online course'), 'on', (o.paid_at at time zone 'Asia/Bangkok')::date,
          'price', case when p_full then o.price_thb end, 'pct', o.affiliate_pct, 'commission', private.aff_ocommission(o), 'state', 'earned')
        from public.web_pkg_orders o where o.affiliate_id = a.id and o.package_id is null and o.course_id is not null and o.paid_at is not null) q), '[]'::jsonb),
    'payouts', case when p_full then coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'amount', p.amount_thb, 'on', p.paid_on, 'method', p.method, 'note', p.note) order by p.paid_on desc)
      from public.affiliate_payouts p where p.affiliate_id = a.id and not p.voided), '[]'::jsonb)
      else coalesce((select jsonb_agg(jsonb_build_object('amount', p.amount_thb, 'on', p.paid_on) order by p.paid_on desc)
      from public.affiliate_payouts p where p.affiliate_id = a.id and not p.voided), '[]'::jsonb) end)
$$;
