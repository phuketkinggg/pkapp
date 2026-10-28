-- Phone notification for every food or drink order from the app (feature: order_push).
-- When a guest orders in the app (to their room or pay at the counter), staff who turned on notifications on their phone get it:
-- by default managers, front desk, resort and kitchen staff (app_settings order_push_roles, a list of roles).

create or replace function public.order_push_targets(p_order uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare o public.shop_orders; who text; room text; items text; roles text[];
begin
  if not private.feature('order_push', true) then return null; end if;
  select * into o from public.shop_orders where id = p_order;
  if o.id is null or o.source <> 'app' then return null; end if;
  roles := coalesce((select array(select jsonb_array_elements_text(a.value::jsonb)) from public.app_settings a where a.key = 'order_push_roles' and a.value ~ '^\s*\['),
    array['manager','front_desk','resort','kitchen']);
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
      where p.off_at is null and s.active and s.role = any (roles)), '[]'::jsonb));
end $f$;
revoke all on function public.order_push_targets(uuid) from public, anon, authenticated;
grant execute on function public.order_push_targets(uuid) to service_role;

-- an app order is placed (it goes from 'void' to 'room' or 'waiting'): ask the chat function to send the notifications (never blocks the order)
create or replace function private.order_push_send() returns trigger language plpgsql security definer set search_path to '' as $f$
declare tok text; base text;
begin
  if new.source is distinct from 'app' or old.status is distinct from 'void' or new.status not in ('room','waiting') then return null; end if;
  if not private.feature('order_push', true) then return null; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  select value into base from private.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'order', 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;
drop trigger if exists shop_orders_push on public.shop_orders;
create trigger shop_orders_push after update of status on public.shop_orders for each row execute function private.order_push_send();

notify pgrst, 'reload schema';
