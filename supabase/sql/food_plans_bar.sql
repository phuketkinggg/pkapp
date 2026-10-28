-- 1) Food plans (feature: food_plans): who has a meal plan, breakfast or another food plan, and for which days.
--    Set on the customer, and made by themselves from room booking extras (cafe) and meal packages.
--    The kitchen and the resort see who has an active plan today, with their room.
-- 2) Coffee and drinks hours (feature: kitchen): like the kitchen, the coffee bar has its own hours and an open or closed switch.
--    When it is closed, app orders for drinks and other non-kitchen items stop. With no hours set it counts as open.

create table if not exists public.food_plans (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  per_day integer check (per_day between 1 and 20),
  starts_on date not null,
  ends_on date,
  note text check (char_length(note) <= 300),
  purchase_id uuid references public.purchases(id) on delete cascade,
  stay_id uuid references public.stays(id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  removed boolean not null default false
);
create index if not exists food_plans_customer on public.food_plans (customer_id);
create unique index if not exists food_plans_purchase on public.food_plans (purchase_id) where purchase_id is not null;
alter table public.food_plans enable row level security;
revoke all on public.food_plans from anon, authenticated;

-- the plans to pick from (Settings, or the add form): app_settings food_plan_types, a list of names
create or replace function private.food_plan_types() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce((select case when jsonb_typeof(value::jsonb) = 'array' and jsonb_array_length(value::jsonb) > 0 then value::jsonb end
                   from public.app_settings where key = 'food_plan_types' and value ~ '^\s*\['),
    '["Meal plan, 3 meals a day","Breakfast","Lunch and dinner","Protein shake"]'::jsonb)
$f$;

-- is the plan live: not removed, its purchase not cancelled, its stay not waiting for payment or cancelled
create or replace function private.food_plan_live(f public.food_plans) returns boolean language sql stable security definer set search_path to '' as $f$
  select not f.removed
    and (f.purchase_id is null or exists (select 1 from public.purchases k where k.id = f.purchase_id and not coalesce(k.cancelled, false) and k.refunded_at is null))
    and (f.stay_id is null or exists (select 1 from public.stays s where s.id = f.stay_id and s.status <> 'cancelled' and s.hold_until is null))
$f$;

-- a customer's plans (staff)
create or replace function public.food_plans_of(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  return jsonb_build_object('types', private.food_plan_types(), 'plans', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'per_day', f.per_day,
      'from', f.starts_on, 'to', f.ends_on, 'note', f.note, 'auto', f.purchase_id is not null) order by f.starts_on desc)
    from public.food_plans f where f.customer_id = p_customer and private.food_plan_live(f)), '[]'::jsonb));
end $f$;

-- add or change a plan (staff)
create or replace function public.food_plan_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v_id uuid := nullif(p->>'id','')::uuid; nm text := left(btrim(coalesce(p->>'name','')), 80); a date; b date; pd int;
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  if nm = '' then raise exception 'Choose the plan.'; end if;
  a := coalesce(nullif(p->>'from','')::date, private.bkk_today()); b := nullif(p->>'to','')::date;
  if b is not null and b < a then raise exception 'The last day must be on or after the first day.'; end if;
  pd := nullif(p->>'per_day','')::numeric::int; if pd is not null and (pd < 1 or pd > 20) then pd := null; end if;
  if v_id is null then
    if not exists (select 1 from public.customers where id = (p->>'customer_id')::uuid) then raise exception 'Customer not found.'; end if;
    insert into public.food_plans (customer_id, name, per_day, starts_on, ends_on, note, created_by)
    values ((p->>'customer_id')::uuid, nm, pd, a, b, nullif(left(btrim(coalesce(p->>'note','')), 300), ''), private.my_staff_id()) returning id into v_id;
  else
    update public.food_plans set name = nm, per_day = pd, starts_on = a, ends_on = b, note = nullif(left(btrim(coalesce(p->>'note','')), 300), '') where id = v_id and not removed;
    if not found then raise exception 'That plan was not found.'; end if;
  end if;
  return v_id;
end $f$;

create or replace function public.food_plan_remove(p_id uuid) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  update public.food_plans set removed = true where id = p_id;
end $f$;

-- who has a plan on a day, with their room (kitchen, front desk, resort)
create or replace function public.food_plans_day(p_day date default null) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare d date := coalesce(p_day, private.bkk_today());
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'room' nulls last, x->>'who') from (
    select jsonb_build_object('id', f.id, 'customer_id', f.customer_id, 'who', c.name, 'plan', f.name, 'per_day', f.per_day, 'from', f.starts_on, 'to', f.ends_on, 'note', f.note,
      'room', (select r.name from public.stays s join public.rooms r on r.id = s.room_id where s.customer_id = f.customer_id and s.status in ('booked','in')
               and s.check_in <= d and s.check_out >= d and s.hold_until is null order by s.check_in desc limit 1)) x
    from public.food_plans f join public.customers c on c.id = f.customer_id
    where f.starts_on <= d and (f.ends_on is null or f.ends_on >= d) and private.food_plan_live(f)) q), '[]'::jsonb);
end $f$;

-- made by themselves: cafe extras on a room booking (Room prices, extras in the cafe group), and meal packages
create or replace function private.food_plan_from_purchase() returns trigger language plpgsql security definer set search_path to '' as $f$
declare e jsonb; nm text;
begin
  if new.cancelled then return null; end if;
  if new.for_stay is not null then
    select x into e from jsonb_array_elements(coalesce((select case when a.value ~ '^\s*\{' then a.value::jsonb->'extras' end from public.app_settings a where a.key = 'room_rates'), '[]'::jsonb)) x
      where x->>'cat' = 'cafe' and position(lower(x->>'name') in lower(new.package_name)) = 1 limit 1;
    if e is not null then nm := e->>'name'; end if;
  end if;
  if nm is null and coalesce(array_length(new.covers, 1), 0) > 0 and new.covers <@ array['Cafe meal']::text[] then nm := new.package_name; end if;
  if nm is null then return null; end if;
  insert into public.food_plans (customer_id, name, per_day, starts_on, ends_on, purchase_id, stay_id)
  values (new.customer_id, left(nm, 80), nullif(e->>'per_day','')::int, coalesce(new.starts_on, private.bkk_today()), new.expires_on, new.id, new.for_stay)
  on conflict (purchase_id) where purchase_id is not null do nothing;
  return null;
exception when others then return null;
end $f$;
drop trigger if exists purchases_food_plan on public.purchases;
create trigger purchases_food_plan after insert on public.purchases for each row execute function private.food_plan_from_purchase();

revoke all on function private.food_plan_types(), private.food_plan_live(public.food_plans), private.food_plan_from_purchase() from public, anon, authenticated;
revoke all on function public.food_plans_of(uuid), public.food_plan_save(jsonb), public.food_plan_remove(uuid), public.food_plans_day(date) from public, anon;
grant execute on function public.food_plans_of(uuid), public.food_plan_save(jsonb), public.food_plan_remove(uuid), public.food_plans_day(date) to authenticated;

-- ---------- coffee and drinks hours ----------
-- the same rules as the kitchen, for any counter: 'kitchen' (food) or 'bar' (coffee and drinks)
create or replace function private.counter_now(p_area text) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare
  hrs jsonb := (select a.value::jsonb from public.app_settings a where a.key = p_area || '_hours' and a.value ~ '^\s*\{');
  stt jsonb := (select a.value::jsonb from public.app_settings a where a.key = p_area || '_state' and a.value ~ '^\s*\{');
  loc timestamp := now() at time zone 'Asia/Bangkok';
  dow int := extract(isodow from loc)::int - 1;
  t time := loc::time;
  lastm int := coalesce((hrs->>'last')::int, case when p_area = 'bar' then 0 else 15 end);
  mode text := 'auto'; untl timestamptz; slot jsonb; o time; c time; i int; nd jsonb; busy boolean := false; bmin int := coalesce((stt->>'busy_min')::int, case when p_area = 'bar' then 15 else 30 end);
  lab text := case when p_area = 'bar' then 'Coffee and drinks' else 'Kitchen' end;
  dn text[] := array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
begin
  if stt is not null and stt->>'mode' in ('open','busy','closed') then
    untl := nullif(stt->>'until','')::timestamptz;
    if untl is null or untl > now() then mode := stt->>'mode'; end if;
  end if;
  if mode = 'closed' then
    return jsonb_build_object('open', false, 'busy', false, 'mode', mode, 'until', untl,
      'text', lab || ' closed' || case when untl is not null then ', opens ' || to_char(untl at time zone 'Asia/Bangkok', 'FMHH24:MI') else ' for now' end || '.'
        || case when p_area = 'kitchen' then ' You can still order drinks at the counter.' else '' end);
  end if;
  busy := mode = 'busy';
  if mode in ('open','busy') then
    return jsonb_build_object('open', true, 'busy', busy, 'mode', mode, 'until', untl,
      'text', case when busy then case when p_area = 'bar' then 'Coffee and drinks are busy, drinks take about ' else 'Kitchen is busy, food takes about ' end || bmin || ' minutes.' else lab || ' open.' end);
  end if;
  if hrs is null or jsonb_typeof(hrs->'days') <> 'array' then
    return jsonb_build_object('open', true, 'busy', false, 'mode', 'auto', 'text', '', 'no_hours', true);
  end if;
  slot := hrs->'days'->dow;
  if slot is not null and jsonb_typeof(slot) = 'array' then
    o := (slot->>0)::time; c := (slot->>1)::time;
    if t >= o and t < c - make_interval(mins => lastm) then
      return jsonb_build_object('open', true, 'busy', false, 'mode', 'auto', 'closes', to_char(c, 'FMHH24:MI'),
        'text', lab || ' open until ' || to_char(c, 'FMHH24:MI') || case when lastm > 0 then ', last orders ' || to_char(c - make_interval(mins => lastm), 'FMHH24:MI') else '' end || '.');
    end if;
    if t < o then
      return jsonb_build_object('open', false, 'busy', false, 'mode', 'auto', 'opens', to_char(o, 'FMHH24:MI'),
        'text', lab || ' closed, opens at ' || to_char(o, 'FMHH24:MI') || ' today.');
    end if;
  end if;
  for i in 1..7 loop
    nd := hrs->'days'->((dow + i) % 7);
    if nd is not null and jsonb_typeof(nd) = 'array' then
      return jsonb_build_object('open', false, 'busy', false, 'mode', 'auto', 'opens', nd->>0,
        'text', lab || ' closed, opens at ' || to_char((nd->>0)::time, 'FMHH24:MI') || case when i = 1 then ' tomorrow.' else ' on ' || dn[((dow + i) % 7) + 1] || '.' end);
    end if;
  end loop;
  return jsonb_build_object('open', false, 'busy', false, 'mode', 'auto', 'text', lab || ' closed.');
end $f$;
revoke all on function private.counter_now(text) from public, anon, authenticated;

create or replace function public.bar_set_mode(p_mode text, p_minutes int default null) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v jsonb;
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  if p_mode not in ('auto','open','busy','closed') then raise exception 'Unknown setting.'; end if;
  if p_minutes is not null and (p_minutes < 5 or p_minutes > 7 * 24 * 60) then raise exception 'Choose a time within the next week.'; end if;
  v := jsonb_build_object('mode', p_mode, 'until', case when p_minutes is not null then now() + make_interval(mins => p_minutes) end, 'busy_min', 15, 'by', private.my_staff_id(), 'at', now());
  insert into public.app_settings (key, value) values ('bar_state', v::text) on conflict (key) do update set value = excluded.value;
  return private.counter_now('bar');
end $f$;

create or replace function public.bar_hours_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare d jsonb; i int; v jsonb := '[]'::jsonb;
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the hours.'; end if;
  if p is null or jsonb_typeof(p->'days') is distinct from 'array' then
    delete from public.app_settings where key = 'bar_hours'; return private.counter_now('bar'); end if;  -- no hours: always open
  if jsonb_array_length(p->'days') <> 7 then raise exception 'Give hours for all 7 days.'; end if;
  for i in 0..6 loop
    d := p->'days'->i;
    if d is null or jsonb_typeof(d) = 'null' then v := v || jsonb_build_array(null);
    else
      if jsonb_typeof(d) <> 'array' or (d->>0) !~ '^\d{1,2}:\d{2}$' or (d->>1) !~ '^\d{1,2}:\d{2}$' or (d->>0)::time >= (d->>1)::time then
        raise exception 'Check the hours: opening must be before closing (like 07:00 to 18:00).'; end if;
      v := v || jsonb_build_array(jsonb_build_array(to_char((d->>0)::time, 'HH24:MI'), to_char((d->>1)::time, 'HH24:MI')));
    end if;
  end loop;
  insert into public.app_settings (key, value) values ('bar_hours', jsonb_build_object('days', v, 'last', least(greatest(coalesce((p->>'last')::int, 0), 0), 120))::text)
    on conflict (key) do update set value = excluded.value;
  return private.counter_now('bar');
end $f$;
revoke all on function public.bar_set_mode(text, int), public.bar_hours_save(jsonb) from public, anon;
grant execute on function public.bar_set_mode(text, int), public.bar_hours_save(jsonb) to authenticated;

do $p$
declare s text;
begin
  -- the kitchen screen also gets the coffee and drinks status and hours
  if to_regprocedure('public.kitchen_info()') is null then raise notice 'no kitchen_info, skipped';
  else
    s := pg_get_functiondef('public.kitchen_info()'::regprocedure);
    if position('counter_now' in s) > 0 then raise notice 'kitchen_info already patched';
    elsif position('''now'', private.kitchen_now(),' in s) = 0 then raise notice 'kitchen_info: older version, skipped';
    else
      s := replace(s, '''now'', private.kitchen_now(),', '''now'', private.kitchen_now(), ''bar'', private.counter_now(''bar''), ''bar_hours'', (select a.value::jsonb from public.app_settings a where a.key = ''bar_hours'' and a.value ~ ''^\s*\{''),');
      execute s;
      if position('counter_now' in pg_get_functiondef('public.kitchen_info()'::regprocedure)) = 0 then raise exception 'kitchen_info patch did not apply'; end if;
    end if;
  end if;
  -- the app menu knows when coffee and drinks are open
  if to_regprocedure('public.shop_catalog()') is null then raise notice 'no shop_catalog, skipped';
  else
    s := pg_get_functiondef('public.shop_catalog()'::regprocedure);
    if position('counter_now' in s) > 0 then raise notice 'shop_catalog already patched';
    elsif position('''kitchen'', private.kitchen_now(),' in s) = 0 then raise notice 'shop_catalog: older version, skipped';
    else
      execute replace(s, '''kitchen'', private.kitchen_now(),', '''kitchen'', private.kitchen_now(), ''bar'', private.counter_now(''bar''),');
      if position('counter_now' in pg_get_functiondef('public.shop_catalog()'::regprocedure)) = 0 then raise exception 'shop_catalog patch did not apply'; end if;
    end if;
  end if;
  -- app orders: drinks and other non-kitchen items only while coffee and drinks are open
  if to_regprocedure('public.shop_app_order(jsonb)') is null then raise notice 'no shop_app_order, skipped';
  else
    s := pg_get_functiondef('public.shop_app_order(jsonb)'::regprocedure);
    if position('counter_now' in s) > 0 then raise notice 'shop_app_order already patched';
    elsif position('anyk boolean := false;' in s) = 0 or position('anyk := anyk or pr.kitchen;' in s) = 0 or position('  update public.shop_orders set subtotal_thb = sub,' in s) = 0 then raise notice 'shop_app_order: older version, skipped';
    else
      s := replace(s, 'anyk boolean := false;', 'anyk boolean := false; anyb boolean := false;');
      s := replace(s, 'anyk := anyk or pr.kitchen;', 'anyk := anyk or pr.kitchen; anyb := anyb or not pr.kitchen;');
      s := replace(s, '  update public.shop_orders set subtotal_thb = sub,', '  if anyb and not coalesce((private.counter_now(''bar'')->>''open'')::boolean, true) then raise exception ''%'', private.counter_now(''bar'')->>''text''; end if;
  update public.shop_orders set subtotal_thb = sub,');
      execute s;
      if position('counter_now' in pg_get_functiondef('public.shop_app_order(jsonb)'::regprocedure)) = 0 then raise exception 'shop_app_order patch did not apply'; end if;
    end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
