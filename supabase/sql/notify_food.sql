-- Food and drink orders in each person's notifications (features order_push and notify_choice).
-- "Food and drink orders from the app" is now one of the choices in Messages, My notifications, and in Everyone's notifications,
-- next to bookings and sales. Anyone (coach, admin, kitchen) can turn it on or off for themselves; a manager can set it for anyone.
-- People who never chose follow their role: managers, admins, front desk, resort and kitchen get it (or the roles in order_push_roles).
-- Everyone who chose their own list before keeps getting food orders if their role got them before.

create or replace function private.push_kinds_ok(p jsonb) returns jsonb language sql immutable as $f$
  select coalesce((select jsonb_agg(distinct k) from jsonb_array_elements_text(coalesce(p, '[]'::jsonb)) k
    where k in ('private','stay','package','class','order','food','sale_package','sale_stay','sale_till')), '[]'::jsonb)
$f$;

create or replace function private.order_push_roles() returns text[] language sql stable security definer set search_path to '' as $f$
  select coalesce((select array(select jsonb_array_elements_text(a.value::jsonb)) from public.app_settings a where a.key = 'order_push_roles' and a.value ~ '^\s*\['),
    array['manager','admin','front_desk','resort','kitchen'])
$f$;
revoke all on function private.order_push_roles() from public, anon, authenticated;

create or replace function public.order_push_targets(p_order uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare o public.shop_orders; who text; room text; items text; roles text[] := private.order_push_roles();
  ppl jsonb := case when private.feature('notify_choice', true) then coalesce(private.booking_push_cfg()->'people', '{}'::jsonb) else '{}'::jsonb end;
begin
  if not private.feature('order_push', true) then return null; end if;
  select * into o from public.shop_orders where id = p_order;
  if o.id is null or o.source <> 'app' then return null; end if;
  select name into who from public.customers where id = o.customer_id;
  select r.name into room from public.stays s join public.rooms r on r.id = s.room_id where s.id = o.stay_id;
  select string_agg(i.qty || ' x ' || i.name, ', ' order by i.name) into items from public.shop_order_items i where i.order_id = o.id;
  return jsonb_build_object(
    'title', 'New order #' || o.number || ': ' || coalesce(room, who, 'app'),
    'body', left(coalesce(items, '') || '. ' || to_char(coalesce(o.total_thb, 0), 'FM999,990') || ' THB, '
      || case when o.status = 'room' then 'on the room bill' else 'pay at the counter' end
      || coalesce('. To: ' || nullif(o.deliver_to, ''), '') || coalesce('. ' || nullif(o.note, ''), ''), 180),
    'order', o.id,
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth))
      from public.push_subs p join public.staff s on s.id = p.staff_id
      where p.off_at is null and s.active
        and case when ppl ? s.id::text then (ppl->s.id::text) ? 'food' else s.role = any (roles) end), '[]'::jsonb));
end $f$;
revoke all on function public.order_push_targets(uuid) from public, anon, authenticated;
grant execute on function public.order_push_targets(uuid) to service_role;

-- people who already chose their own list keep food orders if their role got them before (once)
do $m$
declare c jsonb; k text; v jsonb; r text; n int := 0;
begin
  if exists (select 1 from public.app_settings where key = 'notify_food_done') then return; end if;
  c := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'booking_push'), '{}'::jsonb);
  if jsonb_typeof(c->'people') = 'object' then
    for k, v in select * from jsonb_each(c->'people') loop
      select st.role into r from public.staff st where st.id::text = k;
      if r = any (private.order_push_roles()) and not (v ? 'food') then
        c := jsonb_set(c, array['people', k], v || '["food"]'::jsonb); n := n + 1;
      end if;
    end loop;
    if n > 0 then update public.app_settings set value = c::text where key = 'booking_push'; end if;
  end if;
  insert into public.app_settings(key, value) values ('notify_food_done', 'true') on conflict (key) do nothing;
end $m$;

notify pgrst, 'reload schema';
