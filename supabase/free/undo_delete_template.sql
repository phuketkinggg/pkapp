delete from mf.template where name like 'undo_delete:%';
insert into mf.template (ord, phase, kind, name, sql) values (305901, 3, 'patch', 'undo_delete:305901', $TPL$create table if not exists __Q__.trash (
  id bigserial primary key,
  txid bigint not null default txid_current(),
  at timestamptz not null default now(),
  tbl text not null,
  op text not null,
  row jsonb not null,
  who text,
  restored_at timestamptz,
  restored_by text
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004501, 10, 'patch', 'undo_delete:1004501', $TPL$create index if not exists trash_txid on __Q__.trash (txid);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004502, 10, 'patch', 'undo_delete:1004502', $TPL$create index if not exists trash_at on __Q__.trash (at);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199951, 11, 'patch', 'undo_delete:1199951', $TPL$revoke all on __Q__.trash from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405901, 4, 'patch', 'undo_delete:405901', $TPL$create or replace function __Q__.trash_row() returns trigger language plpgsql security definer set search_path = '' as $f$
declare w text;
begin
  if not __Q__.feature('undo_delete', true) then return coalesce(old, new); end if;
  if tg_op = 'DELETE' then
    begin w := (select s.name from __P__.staff s where s.id = __Q__.my_staff_id()); exception when others then w := null; end;
    insert into __Q__.trash (tbl, op, row, who) values (tg_table_name, 'delete', to_jsonb(old), coalesce(w, 'System'));
    return old;
  end if;
  -- a change made because of a delete in the same step (a check-in losing its package, a payment voided, a visit given back)
  if exists (select 1 from __Q__.trash t where t.txid = txid_current() and t.op = 'delete') then
    insert into __Q__.trash (tbl, op, row) values (tg_table_name, 'update', to_jsonb(old));
  end if;
  return new;
exception when others then return coalesce(new, old);  -- never stop the real change because of the bin
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199952, 11, 'patch', 'undo_delete:1199952', $TPL$revoke all on function __Q__.trash_row() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (904101, 9, 'patch', 'undo_delete:904101', $TPL$do $p$
declare t text; sch text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = '__P__.stays'::regclass);
begin
  foreach t in array array['stays','purchases','privates','shop_orders','shop_order_items','payments','checkins','room_charges','food_plans'] loop
    if to_regclass(format('%I.%I', sch, t)) is not null then
      execute format('drop trigger if exists a_trash_del on %I.%I', sch, t);
      execute format('create trigger a_trash_del before delete on %I.%I for each row execute function __Q__.trash_row()', sch, t);
      execute format('drop trigger if exists a_trash_upd on %I.%I', sch, t);
      execute format('create trigger a_trash_upd before update on %I.%I for each row execute function __Q__.trash_row()', sch, t);
    end if;
  end loop;
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405902, 4, 'patch', 'undo_delete:405902', $TPL$create or replace function __P__.trash_list(p_days int default 30) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'at' desc) from (
    select jsonb_build_object('txid', t.txid, 'at', min(t.at), 'who', max(t.who), 'restored', bool_or(t.restored_at is not null),
      'items', jsonb_agg(jsonb_build_object('tbl', t.tbl,
        'what', coalesce(t.row->>'package_name', t.row->>'name', case t.tbl when 'checkins' then 'Check in ' || (t.row->>'day') when 'payments' then 'Payment ' || (t.row->>'amount_thb') || ' THB'
          when 'stays' then 'Stay ' || (t.row->>'check_in') || ' to ' || (t.row->>'check_out') when 'privates' then 'Private ' || (t.row->>'date') else t.tbl end),
        'customer', (select c.name from __P__.customers c where c.id = nullif(t.row->>'customer_id', '')::uuid)) order by t.id) filter (where t.op = 'delete')) x
    from __Q__.trash t where t.at > now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 60))
    group by t.txid having bool_or(t.op = 'delete')) q), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405903, 4, 'patch', 'undo_delete:405903', $TPL$create or replace function __P__.trash_restore(p_txid bigint) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare sch text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = '__P__.stays'::regclass);
  r record; cols text; n int := 0; u int := 0; who text; ord text[] := array['stays','purchases','privates','shop_orders','shop_order_items','payments','checkins','room_charges','food_plans'];
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can undo a delete.'; end if;
  if not __Q__.feature('undo_delete', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not exists (select 1 from __Q__.trash where txid = p_txid and op = 'delete') then raise exception 'Nothing to undo.'; end if;
  if exists (select 1 from __Q__.trash where txid = p_txid and restored_at is not null) then raise exception 'This was already put back.'; end if;
  who := (select s.name from __P__.staff s where s.id = __Q__.my_staff_id());
  set local session_replication_role = replica;  -- put rows back as they were, without the side effects of a new sale or check-in
  for r in select t.* from __Q__.trash t where t.txid = p_txid and t.op = 'delete' order by array_position(ord, t.tbl), t.id loop
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols from pg_attribute a
      where a.attrelid = format('%I.%I', sch, r.tbl)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
    execute format('insert into %I.%I (%s) select %s from jsonb_populate_record(null::%I.%I, $1) on conflict do nothing', sch, r.tbl, cols, cols, sch, r.tbl) using r.row;
    n := n + 1;
  end loop;
  for r in select t.* from __Q__.trash t where t.txid = p_txid and t.op = 'update' order by t.id desc loop
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols from pg_attribute a
      where a.attrelid = format('%I.%I', sch, r.tbl)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '' and a.attname <> 'id';
    execute format('update %I.%I t set (%s) = (select %s from jsonb_populate_record(null::%I.%I, $1)) where t.id = ($1->>''id'')::uuid', sch, r.tbl, cols, cols, sch, r.tbl) using r.row;
    u := u + 1;
  end loop;
  update __Q__.trash set restored_at = now(), restored_by = who where txid = p_txid;
  return jsonb_build_object('ok', true, 'restored', n, 'changes_undone', u);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199953, 11, 'patch', 'undo_delete:1199953', $TPL$revoke all on function __P__.trash_list(int), __P__.trash_restore(bigint) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199954, 11, 'patch', 'undo_delete:1199954', $TPL$grant execute on function __P__.trash_list(int), __P__.trash_restore(bigint) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405904, 4, 'patch', 'undo_delete:405904', $TPL$create or replace function __P__.purchase_redate(p_id uuid, p_day date, p_move_payments boolean default true) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare k __P__.purchases; m int := 0;
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change the bought date.'; end if;
  if not __Q__.feature('redate_purchase', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if p_day is null or p_day > __Q__.bkk_today() + 366 or p_day < date '2000-01-01' then raise exception 'Choose a real date.'; end if;
  select * into k from __P__.purchases where id = p_id for update;
  if k.id is null then raise exception 'Package not found.'; end if;
  if p_move_payments then
    update __P__.payments set day = p_day where purchase_id = p_id and day = k.purchased_on and not coalesce(voided, false);
    get diagnostics m = row_count;
  end if;
  update __P__.purchases set purchased_on = p_day where id = p_id;
  return jsonb_build_object('ok', true, 'payments_moved', m);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199955, 11, 'patch', 'undo_delete:1199955', $TPL$revoke all on function __P__.purchase_redate(uuid, date, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199956, 11, 'patch', 'undo_delete:1199956', $TPL$grant execute on function __P__.purchase_redate(uuid, date, boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004503, 10, 'patch', 'undo_delete:1004503', $TPL$do $p$ declare q text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = '__Q__.trash'::regclass);
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'trash-trim-' || q;
    perform cron.schedule('trash-trim-' || q, '45 3 * * *', format('delete from %I.trash where at < now() - interval ''60 days''', q));
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'undo_delete:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
