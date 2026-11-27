delete from mf.template where name like 'notify_food:%';
insert into mf.template (ord, phase, kind, name, sql) values (406101, 4, 'patch', 'notify_food:406101', $TPL$create or replace function __Q__.push_kinds_ok(p jsonb) returns jsonb language sql immutable as $f$
  select coalesce((select jsonb_agg(distinct k) from jsonb_array_elements_text(coalesce(p, '[]'::jsonb)) k
    where k in ('private','stay','package','class','order','food','sale_package','sale_stay','sale_till')), '[]'::jsonb)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406102, 4, 'patch', 'notify_food:406102', $TPL$create or replace function __Q__.order_push_roles() returns text[] language sql stable security definer set search_path to '' as $f$
  select coalesce((select array(select jsonb_array_elements_text(a.value::jsonb)) from __P__.app_settings a where a.key = 'order_push_roles' and a.value ~ '^\s*\['),
    array['manager','admin','front_desk','resort','kitchen'])
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199971, 11, 'patch', 'notify_food:1199971', $TPL$revoke all on function __Q__.order_push_roles() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406103, 4, 'patch', 'notify_food:406103', $TPL$create or replace function __P__.order_push_targets(p_order uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare o __P__.shop_orders; who text; room text; items text; roles text[] := __Q__.order_push_roles();
  ppl jsonb := case when __Q__.feature('notify_choice', true) then coalesce(__Q__.booking_push_cfg()->'people', '{}'::jsonb) else '{}'::jsonb end;
begin
  if not __Q__.feature('order_push', true) then return null; end if;
  select * into o from __P__.shop_orders where id = p_order;
  if o.id is null or o.source <> 'app' then return null; end if;
  select name into who from __P__.customers where id = o.customer_id;
  select r.name into room from __P__.stays s join __P__.rooms r on r.id = s.room_id where s.id = o.stay_id;
  select string_agg(i.qty || ' x ' || i.name, ', ' order by i.name) into items from __P__.shop_order_items i where i.order_id = o.id;
  return jsonb_build_object(
    'title', 'New order #' || o.number || ': ' || coalesce(room, who, 'app'),
    'body', left(coalesce(items, '') || '. ' || to_char(coalesce(o.total_thb, 0), 'FM999,990') || ' THB, '
      || case when o.status = 'room' then 'on the room bill' else 'pay at the counter' end
      || coalesce('. To: ' || nullif(o.deliver_to, ''), '') || coalesce('. ' || nullif(o.note, ''), ''), 180),
    'order', o.id,
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth))
      from __P__.push_subs p join __P__.staff s on s.id = p.staff_id
      where p.off_at is null and s.active
        and case when ppl ? s.id::text then (ppl->s.id::text) ? 'food' else s.role = any (roles) end), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199972, 11, 'patch', 'notify_food:1199972', $TPL$revoke all on function __P__.order_push_targets(uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199973, 11, 'patch', 'notify_food:1199973', $TPL$grant execute on function __P__.order_push_targets(uuid) to service_role;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004701, 10, 'patch', 'notify_food:1004701', $TPL$do $m$
declare c jsonb; k text; v jsonb; r text; n int := 0;
begin
  if exists (select 1 from __P__.app_settings where key = 'notify_food_done') then return; end if;
  c := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'booking_push'), '{}'::jsonb);
  if jsonb_typeof(c->'people') = 'object' then
    for k, v in select * from jsonb_each(c->'people') loop
      select st.role into r from __P__.staff st where st.id::text = k;
      if r = any (__Q__.order_push_roles()) and not (v ? 'food') then
        c := jsonb_set(c, array['people', k], v || '["food"]'::jsonb); n := n + 1;
      end if;
    end loop;
    if n > 0 then update __P__.app_settings set value = c::text where key = 'booking_push'; end if;
  end if;
  insert into __P__.app_settings(key, value) values ('notify_food_done', 'true') on conflict (key) do nothing;
end $m$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'notify_food:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
