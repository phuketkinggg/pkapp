-- Kitchen open and close: set hours, an override switch on the kitchen screen (Open, Busy, Closed), and sold out for today.
-- The app menu follows it: when the kitchen is closed, food orders from the app are refused with the opening time.
-- Till orders are not blocked (staff decide), drinks and other non-kitchen items always sell.
-- With no hours set the kitchen counts as open, so nothing changes until a manager sets hours.

alter table public.shop_products add column if not exists sold_out_on date;

-- hours: {"days":[["07:30","20:30"], ... 7 entries, Monday first, null = closed all day], "last": 15}
-- state: {"mode":"open"|"busy"|"closed", "until":"2026-10-24T13:00:00Z" or null, "busy_min": 30}
create or replace function private.kitchen_now()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  hrs jsonb := (select a.value::jsonb from public.app_settings a where a.key = 'kitchen_hours' and a.value ~ '^\s*\{');
  stt jsonb := (select a.value::jsonb from public.app_settings a where a.key = 'kitchen_state' and a.value ~ '^\s*\{');
  loc timestamp := now() at time zone 'Asia/Bangkok';
  dow int := extract(isodow from loc)::int - 1;
  t time := loc::time;
  lastm int := coalesce((hrs->>'last')::int, 15);
  mode text := 'auto'; untl timestamptz; slot jsonb; o time; c time; i int; nd jsonb; busy boolean := false; bmin int := coalesce((stt->>'busy_min')::int, 30);
  dn text[] := array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
begin
  if stt is not null and stt->>'mode' in ('open','busy','closed') then
    untl := nullif(stt->>'until','')::timestamptz;
    if untl is null or untl > now() then mode := stt->>'mode'; end if;
  end if;
  if mode = 'closed' then
    return jsonb_build_object('open', false, 'busy', false, 'mode', mode, 'until', untl,
      'text', 'Kitchen closed' || case when untl is not null then ', opens ' || to_char(untl at time zone 'Asia/Bangkok', 'FMHH24:MI') else ' for now' end || '. You can still order drinks at the counter.');
  end if;
  busy := mode = 'busy';
  if mode in ('open','busy') then
    return jsonb_build_object('open', true, 'busy', busy, 'mode', mode, 'until', untl,
      'text', case when busy then 'Kitchen is busy, food takes about ' || bmin || ' minutes.' else 'Kitchen open.' end);
  end if;
  -- auto: follow the hours
  if hrs is null or jsonb_typeof(hrs->'days') <> 'array' then
    return jsonb_build_object('open', true, 'busy', false, 'mode', 'auto', 'text', '', 'no_hours', true);
  end if;
  slot := hrs->'days'->dow;
  if slot is not null and jsonb_typeof(slot) = 'array' then
    o := (slot->>0)::time; c := (slot->>1)::time;
    if t >= o and t < c - make_interval(mins => lastm) then
      return jsonb_build_object('open', true, 'busy', false, 'mode', 'auto', 'closes', to_char(c, 'FMHH24:MI'),
        'text', 'Kitchen open until ' || to_char(c, 'FMHH24:MI') || ', last orders ' || to_char(c - make_interval(mins => lastm), 'FMHH24:MI') || '.');
    end if;
    if t < o then
      return jsonb_build_object('open', false, 'busy', false, 'mode', 'auto', 'opens', to_char(o, 'FMHH24:MI'),
        'text', 'Kitchen closed, opens at ' || to_char(o, 'FMHH24:MI') || ' today.');
    end if;
  end if;
  for i in 1..7 loop
    nd := hrs->'days'->((dow + i) % 7);
    if nd is not null and jsonb_typeof(nd) = 'array' then
      return jsonb_build_object('open', false, 'busy', false, 'mode', 'auto', 'opens', nd->>0,
        'text', 'Kitchen closed, opens at ' || to_char((nd->>0)::time, 'FMHH24:MI') || case when i = 1 then ' tomorrow.' else ' on ' || dn[((dow + i) % 7) + 1] || '.' end);
    end if;
  end loop;
  return jsonb_build_object('open', false, 'busy', false, 'mode', 'auto', 'text', 'Kitchen closed.');
end $$;

-- kitchen screen: status, hours, the switch, and the kitchen dishes with sold out
create or replace function public.kitchen_info()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'now', private.kitchen_now(),
    'hours', (select a.value::jsonb from public.app_settings a where a.key = 'kitchen_hours' and a.value ~ '^\s*\{'),
    'manager', private.staff_role() = 'manager',
    'dishes', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'sold_out', coalesce(p.sold_out_on = private.bkk_today(), false)) order by p.sort, p.name), '[]'::jsonb)
               from public.shop_products p where p.active and p.kitchen and p.in_app));
end $$;

create or replace function public.kitchen_set_mode(p_mode text, p_minutes int default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v jsonb;
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  if p_mode not in ('auto','open','busy','closed') then raise exception 'Unknown setting.'; end if;
  if p_minutes is not null and (p_minutes < 5 or p_minutes > 7 * 24 * 60) then raise exception 'Choose a time within the next week.'; end if;
  v := jsonb_build_object('mode', p_mode, 'until', case when p_minutes is not null then now() + make_interval(mins => p_minutes) end, 'busy_min', 30, 'by', private.my_staff_id(), 'at', now());
  insert into public.app_settings (key, value) values ('kitchen_state', v::text)
    on conflict (key) do update set value = excluded.value;
  return private.kitchen_now();
end $$;

create or replace function public.kitchen_sold_out(p_product uuid, p_out boolean)
returns boolean language plpgsql security definer set search_path to '' as $$
begin
  if not private.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  update public.shop_products set sold_out_on = case when p_out then private.bkk_today() end where id = p_product and kitchen;
  return found;
end $$;

create or replace function public.kitchen_hours_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare d jsonb; i int; v jsonb := '[]'::jsonb;
begin
  if private.staff_role() <> 'manager' then raise exception 'Only a manager can change the kitchen hours.'; end if;
  if jsonb_typeof(p->'days') <> 'array' or jsonb_array_length(p->'days') <> 7 then raise exception 'Give hours for all 7 days.'; end if;
  for i in 0..6 loop
    d := p->'days'->i;
    if d is null or jsonb_typeof(d) = 'null' then v := v || jsonb_build_array(null);
    else
      if jsonb_typeof(d) <> 'array' or (d->>0) !~ '^\d{1,2}:\d{2}$' or (d->>1) !~ '^\d{1,2}:\d{2}$' or (d->>0)::time >= (d->>1)::time then
        raise exception 'Check the hours: opening must be before closing (like 07:30 to 20:30).'; end if;
      v := v || jsonb_build_array(jsonb_build_array(to_char((d->>0)::time, 'HH24:MI'), to_char((d->>1)::time, 'HH24:MI')));
    end if;
  end loop;
  insert into public.app_settings (key, value) values ('kitchen_hours', jsonb_build_object('days', v, 'last', least(greatest(coalesce((p->>'last')::int, 15), 0), 120))::text)
    on conflict (key) do update set value = excluded.value;
  return private.kitchen_now();
end $$;

revoke all on function private.kitchen_now() from public, anon;
revoke all on function public.kitchen_info() from public, anon;
revoke all on function public.kitchen_set_mode(text, int) from public, anon;
revoke all on function public.kitchen_sold_out(uuid, boolean) from public, anon;
revoke all on function public.kitchen_hours_save(jsonb) from public, anon;
grant execute on function public.kitchen_info() to authenticated;
grant execute on function public.kitchen_set_mode(text, int) to authenticated;
grant execute on function public.kitchen_sold_out(uuid, boolean) to authenticated;
grant execute on function public.kitchen_hours_save(jsonb) to authenticated;

-- the menu in the app shows the kitchen status and sold out dishes
do $$ declare s text;
begin
  s := pg_get_functiondef('public.shop_catalog()'::regprocedure);
  if s not like '%kitchen_now%' then
    s := replace(s, $a$'role', role,$a$, $a$'role', role, 'kitchen', private.kitchen_now(),$a$);
    s := replace(s, $a$'image_url', p.image_url,$a$, $a$'image_url', p.image_url, 'sold_out', coalesce(p.sold_out_on = private.bkk_today(), false),$a$);
    if s not like '%kitchen_now%' or s not like '%sold_out%' then raise exception 'shop_catalog patch did not apply'; end if;
    execute s;
  end if;
end $$;

-- app orders: no sold out dishes, and food only while the kitchen is open
do $$ declare s text;
begin
  s := pg_get_functiondef('public.shop_app_order(jsonb)'::regprocedure);
  if s not like '%kitchen_now%' then
    s := replace(s, $a$    if pr.id is null then raise exception 'Something in your order is not available right now.'; end if;$a$,
      $a$    if pr.id is null then raise exception 'Something in your order is not available right now.'; end if;
    if pr.sold_out_on = private.bkk_today() then raise exception '% is sold out today.', pr.name; end if;$a$);
    s := replace(s, $a$  update public.shop_orders set subtotal_thb = sub,$a$,
      $a$  if anyk and not coalesce((private.kitchen_now()->>'open')::boolean, true) then raise exception '%', private.kitchen_now()->>'text'; end if;
  update public.shop_orders set subtotal_thb = sub,$a$);
    if s not like '%kitchen_now%' or s not like '%sold out today%' then raise exception 'shop_app_order patch did not apply'; end if;
    execute s;
  end if;
end $$;
