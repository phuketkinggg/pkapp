-- Undo a delete (feature undo_delete, on by default), and change the date a package was bought (feature redate_purchase).
--
-- Undo: everything deleted from packages, privates, stays, check-ins, payments, shop sales, room charges and food plans
-- is kept for 60 days, together with what changed because of it (check-ins that lost their package, payments voided,
-- visits given back). Settings, Activity, Recently deleted lists each delete, and Undo puts it all back as it was.
--
-- Change the bought date: Edit on a package lets a manager change Bought on. Its payments taken on the old date move
-- to the new date too, so Accounts shows the money on the day it really came in.

create table if not exists private.trash (
  id bigserial primary key,
  txid bigint not null default txid_current(),
  at timestamptz not null default now(),
  tbl text not null,
  op text not null,
  row jsonb not null,
  who text,
  restored_at timestamptz,
  restored_by text
);
create index if not exists trash_txid on private.trash (txid);
create index if not exists trash_at on private.trash (at);
revoke all on private.trash from public, anon, authenticated;

create or replace function private.trash_row() returns trigger language plpgsql security definer set search_path = '' as $f$
declare w text;
begin
  if not private.feature('undo_delete', true) then return coalesce(old, new); end if;
  if tg_op = 'DELETE' then
    begin w := (select s.name from public.staff s where s.id = private.my_staff_id()); exception when others then w := null; end;
    insert into private.trash (tbl, op, row, who) values (tg_table_name, 'delete', to_jsonb(old), coalesce(w, 'System'));
    return old;
  end if;
  -- a change made because of a delete in the same step (a check-in losing its package, a payment voided, a visit given back)
  if exists (select 1 from private.trash t where t.txid = txid_current() and t.op = 'delete') then
    insert into private.trash (tbl, op, row) values (tg_table_name, 'update', to_jsonb(old));
  end if;
  return new;
exception when others then return coalesce(new, old);  -- never stop the real change because of the bin
end $f$;
revoke all on function private.trash_row() from public, anon, authenticated;

do $p$
declare t text; sch text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = 'public.stays'::regclass);
begin
  foreach t in array array['stays','purchases','privates','shop_orders','shop_order_items','payments','checkins','room_charges','food_plans'] loop
    if to_regclass(format('%I.%I', sch, t)) is not null then
      execute format('drop trigger if exists a_trash_del on %I.%I', sch, t);
      execute format('create trigger a_trash_del before delete on %I.%I for each row execute function private.trash_row()', sch, t);
      execute format('drop trigger if exists a_trash_upd on %I.%I', sch, t);
      execute format('create trigger a_trash_upd before update on %I.%I for each row execute function private.trash_row()', sch, t);
    end if;
  end loop;
end $p$;

-- what was deleted lately, one line per delete
create or replace function public.trash_list(p_days int default 30) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'at' desc) from (
    select jsonb_build_object('txid', t.txid, 'at', min(t.at), 'who', max(t.who), 'restored', bool_or(t.restored_at is not null),
      'items', jsonb_agg(jsonb_build_object('tbl', t.tbl,
        'what', coalesce(t.row->>'package_name', t.row->>'name', case t.tbl when 'checkins' then 'Check in ' || (t.row->>'day') when 'payments' then 'Payment ' || (t.row->>'amount_thb') || ' THB'
          when 'stays' then 'Stay ' || (t.row->>'check_in') || ' to ' || (t.row->>'check_out') when 'privates' then 'Private ' || (t.row->>'date') else t.tbl end),
        'customer', (select c.name from public.customers c where c.id = nullif(t.row->>'customer_id', '')::uuid)) order by t.id) filter (where t.op = 'delete')) x
    from private.trash t where t.at > now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 60))
    group by t.txid having bool_or(t.op = 'delete')) q), '[]'::jsonb);
end $f$;

-- put back everything from one delete, as it was
create or replace function public.trash_restore(p_txid bigint) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare sch text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = 'public.stays'::regclass);
  r record; cols text; n int := 0; u int := 0; v_who text; ord text[] := array['stays','purchases','privates','shop_orders','shop_order_items','payments','checkins','room_charges','food_plans'];
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can undo a delete.'; end if;
  if not private.feature('undo_delete', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not exists (select 1 from private.trash where txid = p_txid and op = 'delete') then raise exception 'Nothing to undo.'; end if;
  if exists (select 1 from private.trash where txid = p_txid and restored_at is not null) then raise exception 'This was already put back.'; end if;
  v_who := (select s.name from public.staff s where s.id = private.my_staff_id());
  set local session_replication_role = replica;  -- put rows back as they were, without the side effects of a new sale or check-in
  for r in select t.* from private.trash t where t.txid = p_txid and t.op = 'delete' order by array_position(ord, t.tbl), t.id loop
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols from pg_attribute a
      where a.attrelid = format('%I.%I', sch, r.tbl)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
    execute format('insert into %I.%I (%s) select %s from jsonb_populate_record(null::%I.%I, $1) on conflict do nothing', sch, r.tbl, cols, cols, sch, r.tbl) using r.row;
    n := n + 1;
  end loop;
  for r in select t.* from private.trash t where t.txid = p_txid and t.op = 'update' order by t.id desc loop
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols from pg_attribute a
      where a.attrelid = format('%I.%I', sch, r.tbl)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '' and a.attname <> 'id';
    execute format('update %I.%I t set (%s) = (select %s from jsonb_populate_record(null::%I.%I, $1)) where t.id = ($1->>''id'')::uuid', sch, r.tbl, cols, cols, sch, r.tbl) using r.row;
    u := u + 1;
  end loop;
  update private.trash set restored_at = now(), restored_by = v_who where txid = p_txid;
  return jsonb_build_object('ok', true, 'restored', n, 'changes_undone', u);
end $f$;
revoke all on function public.trash_list(int), public.trash_restore(bigint) from public, anon;
grant execute on function public.trash_list(int), public.trash_restore(bigint) to authenticated;

-- change the date a package was bought; its payments on the old date move with it
create or replace function public.purchase_redate(p_id uuid, p_day date, p_move_payments boolean default true) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare k public.purchases; m int := 0;
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change the bought date.'; end if;
  if not private.feature('redate_purchase', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if p_day is null or p_day > private.bkk_today() + 366 or p_day < date '2000-01-01' then raise exception 'Choose a real date.'; end if;
  select * into k from public.purchases where id = p_id for update;
  if k.id is null then raise exception 'Package not found.'; end if;
  if p_move_payments then
    update public.payments set day = p_day where purchase_id = p_id and day = k.purchased_on and not coalesce(voided, false);
    get diagnostics m = row_count;
  end if;
  update public.purchases set purchased_on = p_day where id = p_id;
  return jsonb_build_object('ok', true, 'payments_moved', m);
end $f$;
revoke all on function public.purchase_redate(uuid, date, boolean) from public, anon;
grant execute on function public.purchase_redate(uuid, date, boolean) to authenticated;

-- keep the bin for 60 days
do $p$ declare q text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = 'private.trash'::regclass);
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'trash-trim-' || q;
    perform cron.schedule('trash-trim-' || q, '45 3 * * *', format('delete from %I.trash where at < now() - interval ''60 days''', q));
  end if;
end $p$;

notify pgrst, 'reload schema';
