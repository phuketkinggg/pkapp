delete from mf.template where name like 'audit_log:%';
insert into mf.template (ord, phase, kind, name, sql) values (302501, 3, 'patch', 'audit_log:302501', $TPL$create table if not exists __Q__.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  tbl text not null,
  row_id uuid,
  action text not null check (action in ('add','change','delete')),
  changes jsonb,
  staff_id uuid,
  user_id uuid,
  who text
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001201, 10, 'patch', 'audit_log:1001201', $TPL$create index if not exists audit_log_row on __Q__.audit_log (tbl, row_id, at desc);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001202, 10, 'patch', 'audit_log:1001202', $TPL$create index if not exists audit_log_at on __Q__.audit_log (at desc);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196601, 11, 'patch', 'audit_log:1196601', $TPL$revoke all on __Q__.audit_log from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402601, 4, 'patch', 'audit_log:402601', $TPL$create or replace function __Q__.audit_skip() returns text[] language sql immutable as $f$
  select array['updated_at','app_paid_thb','search','tsv','last_seen','last_seen_at','unread','synced_at','mp_price','ical_seen','paid_thb','pin_hash','password','token']
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402602, 4, 'patch', 'audit_log:402602', $TPL$create or replace function __Q__.audit_row() returns trigger language plpgsql security definer set search_path to '' as $f$
declare o jsonb; n jsonb; d jsonb := '{}'::jsonb; k text; sid uuid; uid uuid; w text;
begin
  if not __Q__.feature('audit_log', true) then return null; end if;
  begin
    uid := auth.uid();
    sid := __Q__.my_staff_id();
  exception when others then uid := null; sid := null; end;
  w := case when sid is not null then (select s.name from __P__.staff s where s.id = sid)
            when uid is not null then coalesce((select 'Member: ' || c.name from __P__.customers c where c.user_id = uid limit 1), 'Signed in user')
            else 'System (website, booking sites or automatic)' end;
  if tg_op = 'INSERT' then
    n := to_jsonb(new) - __Q__.audit_skip();
    insert into __Q__.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values (tg_table_name, (n->>'id')::uuid, 'add', jsonb_strip_nulls(n), sid, uid, w);
  elsif tg_op = 'UPDATE' then
    o := to_jsonb(old); n := to_jsonb(new);
    for k in select jsonb_object_keys(n) loop
      if k = any (__Q__.audit_skip()) then continue; end if;
      if (o->k) is distinct from (n->k) then d := d || jsonb_build_object(k, jsonb_build_array(o->k, n->k)); end if;
    end loop;
    if d = '{}'::jsonb then return null; end if;
    insert into __Q__.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values (tg_table_name, (n->>'id')::uuid, 'change', d, sid, uid, w);
  elsif tg_table_name = 'customers' then
    -- a deleted customer (for example who deleted their account) leaves no personal details in the log
    delete from __Q__.audit_log where tbl = 'customers' and row_id = old.id;
    insert into __Q__.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values ('customers', old.id, 'delete', '{}'::jsonb, sid, uid, w);
  else
    o := to_jsonb(old) - __Q__.audit_skip();
    insert into __Q__.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values (tg_table_name, (o->>'id')::uuid, 'delete', jsonb_strip_nulls(o), sid, uid, w);
  end if;
  return null;
exception when others then return null;  -- never stop the real change because of the log
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900801, 9, 'patch', 'audit_log:900801', $TPL$do $p$
declare t text;
begin
  foreach t in array array['stays','privates','purchases','payments','room_charges','customers','staff','packages','shop_products','shop_orders'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('drop trigger if exists zz_audit on public.%I', t);
    execute format('create trigger zz_audit after insert or update or delete on public.%I for each row execute function __Q__.audit_row()', t);
  end loop;
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402603, 4, 'patch', 'audit_log:402603', $TPL$create or replace function __P__.audit_list(p_tbl text, p_row uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'tbl', a.tbl, 'action', a.action, 'changes', a.changes, 'who', a.who) order by a.at desc)
    from (select * from __Q__.audit_log a where a.row_id = p_row and (p_tbl is null or a.tbl = p_tbl) order by a.at desc limit 200) a), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402604, 4, 'patch', 'audit_log:402604', $TPL$create or replace function __P__.audit_recent(p_days integer default 7, p_tbl text default null, p_who text default null) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'tbl', a.tbl, 'row_id', a.row_id, 'action', a.action, 'changes', a.changes, 'who', a.who) order by a.at desc)
    from (select * from __Q__.audit_log a where a.at > now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 365))
            and (p_tbl is null or a.tbl = p_tbl) and (p_who is null or a.who = p_who) order by a.at desc limit 500) a), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196602, 11, 'patch', 'audit_log:1196602', $TPL$revoke all on function __P__.audit_list(text, uuid), __P__.audit_recent(integer, text, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196603, 11, 'patch', 'audit_log:1196603', $TPL$grant execute on function __P__.audit_list(text, uuid), __P__.audit_recent(integer, text, text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001203, 10, 'patch', 'audit_log:1001203', $TPL$do $p$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'audit-trim';
    perform cron.schedule('audit-trim', '40 3 * * *', 'delete from __Q__.audit_log where at < now() - interval ''365 days''');
  end if;
exception when others then raise notice 'audit-trim not scheduled: %', sqlerrm;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'audit_log:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
