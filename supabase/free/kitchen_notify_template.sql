delete from mf.template where name like 'kitchen_notify:%';
insert into mf.template (ord, phase, kind, name, sql) values (406401, 4, 'patch', 'kitchen_notify:406401', $TPL$create or replace function __Q__.kitchen_gets(p_staff uuid, p_role text) returns boolean language sql stable security definer set search_path = '' as $f$
  select case when coalesce(__Q__.booking_push_cfg()->'people', '{}'::jsonb) ? p_staff::text
    then (__Q__.booking_push_cfg()->'people'->p_staff::text) ? 'food' else p_role = any (__Q__.order_push_roles()) end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199996, 11, 'patch', 'kitchen_notify:1199996', $TPL$revoke all on function __Q__.kitchen_gets(uuid, text) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406402, 4, 'patch', 'kitchen_notify:406402', $TPL$create or replace function __P__.order_push_targets(p_order uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare o __P__.shop_orders; who text; room text; items text; app boolean;
begin
  if not __Q__.feature('order_push', true) then return null; end if;
  select * into o from __P__.shop_orders where id = p_order;
  if o.id is null or o.status = 'void' then return null; end if;
  app := o.source = 'app';
  if not app and coalesce(to_jsonb(o)->>'kitchen_status', '') <> 'new' then return null; end if;
  select name into who from __P__.customers where id = o.customer_id;
  select r.name into room from __P__.stays s join __P__.rooms r on r.id = s.room_id where s.id = o.stay_id;
  -- from the app: everything ordered; otherwise what the kitchen has to make now (a new round on a tab)
  select string_agg(i.qty || ' x ' || i.name, ', ' order by i.name) into items from __P__.shop_order_items i
    where i.order_id = o.id and not coalesce(i.removed, false)
      and (app or (coalesce((to_jsonb(i)->>'kitchen')::boolean, false) and coalesce((to_jsonb(i)->>'kround')::int, 0) > coalesce((to_jsonb(o)->>'kdone_round')::int, 0)));
  if not app and items is null then return null; end if;
  return jsonb_build_object(
    'title', 'New order #' || o.number || ': ' || coalesce(room, nullif(to_jsonb(o)->>'tab_name', ''), nullif(o.deliver_to, ''), who, case when app then 'app' else 'till' end),
    'body', left(coalesce(items, '') || case when app then '. ' || to_char(coalesce(o.total_thb, 0), 'FM999,990') || ' THB, '
      || case when o.status = 'room' then 'on the room bill' else 'pay at the counter' end else '' end
      || coalesce('. To: ' || nullif(o.deliver_to, ''), '') || coalesce('. ' || nullif(o.note, ''), ''), 180),
    'order', o.id,
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth))
      from __P__.push_subs p join __P__.staff s on s.id = p.staff_id
      where p.off_at is null and s.active and __Q__.kitchen_gets(s.id, s.role)), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199997, 11, 'patch', 'kitchen_notify:1199997', $TPL$revoke all on function __P__.order_push_targets(uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199998, 11, 'patch', 'kitchen_notify:1199998', $TPL$grant execute on function __P__.order_push_targets(uuid) to service_role;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406403, 4, 'patch', 'kitchen_notify:406403', $TPL$create or replace function __Q__.order_push_send() returns trigger language plpgsql security definer set search_path to '' as $f$
declare tok text; base text; go boolean;
begin
  if new.source = 'app' then
    go := tg_op = 'UPDATE' and old.status = 'void' and new.status in ('room','waiting');
  else
    go := coalesce(to_jsonb(new)->>'kitchen_status', '') = 'new' and new.status <> 'void'
      and (tg_op = 'INSERT' or (to_jsonb(old)->>'kitchen_status') is distinct from 'new' or old.status = 'void');
  end if;
  if not go or not __Q__.feature('order_push', true) then return null; end if;
  select value into tok from __Q__.sync_settings where key = 'sync_token';
  select value into base from __Q__.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'order', 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (904301, 9, 'patch', 'kitchen_notify:904301', $TPL$do $t$ declare sch text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = '__P__.shop_orders'::regclass);
begin
  execute format('drop trigger if exists shop_orders_push on %I.shop_orders', sch);
  if exists (select 1 from pg_attribute where attrelid = '__P__.shop_orders'::regclass and attname = 'kitchen_status' and not attisdropped) then
    execute format('create trigger shop_orders_push after insert or update of status, kitchen_status on %I.shop_orders for each row execute function __Q__.order_push_send()', sch);
  else
    execute format('create trigger shop_orders_push after update of status on %I.shop_orders for each row execute function __Q__.order_push_send()', sch);
  end if;
end $t$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406404, 4, 'patch', 'kitchen_notify:406404', $TPL$create or replace function __P__.kitchen_team() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if not __Q__.shop_kitchen_ok() then raise exception 'Not allowed.'; end if;
  return jsonb_build_object('can', coalesce(__Q__.staff_role(), '') = 'manager', 'me', __Q__.my_staff_id(),
    'people', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', s.role, 'on', __Q__.kitchen_gets(s.id, s.role),
      'phone', exists (select 1 from __P__.push_subs x where x.staff_id = s.id and x.off_at is null)) order by not __Q__.kitchen_gets(s.id, s.role), s.name)
    from __P__.staff s where s.active and s.user_id is not null and s.role <> 'investor'), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199999, 11, 'patch', 'kitchen_notify:1199999', $TPL$revoke all on function __P__.kitchen_team() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1200000, 11, 'patch', 'kitchen_notify:1200000', $TPL$grant execute on function __P__.kitchen_team() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406405, 4, 'patch', 'kitchen_notify:406405', $TPL$create or replace function __P__.kitchen_team_set(p_staff uuid, p_on boolean) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare c jsonb; s __P__.staff; k jsonb;
begin
  if not (coalesce(__Q__.staff_role(), '') = 'manager' or p_staff = __Q__.my_staff_id()) then raise exception 'Only a manager or admin can change who gets kitchen orders.'; end if;
  select * into s from __P__.staff where id = p_staff and active;
  if s.id is null then raise exception 'Person not found.'; end if;
  c := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'booking_push'), '{}'::jsonb);
  k := case when coalesce(c->'people', '{}'::jsonb) ? s.id::text then c->'people'->s.id::text
    when (__Q__.booking_push_cfg()->'roles') ? s.role then __Q__.booking_push_cfg()->'kinds' else '[]'::jsonb end;
  k := coalesce((select jsonb_agg(distinct x) from jsonb_array_elements_text(k) x where x <> 'food'), '[]'::jsonb) || case when p_on then '["food"]'::jsonb else '[]'::jsonb end;
  c := jsonb_set(c, '{people}', coalesce(c->'people', '{}'::jsonb) || jsonb_build_object(s.id::text, k));
  insert into __P__.app_settings(key, value) values ('booking_push', c::text) on conflict (key) do update set value = excluded.value;
  return __P__.kitchen_team();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1200001, 11, 'patch', 'kitchen_notify:1200001', $TPL$revoke all on function __P__.kitchen_team_set(uuid, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1200002, 11, 'patch', 'kitchen_notify:1200002', $TPL$grant execute on function __P__.kitchen_team_set(uuid, boolean) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'kitchen_notify:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
