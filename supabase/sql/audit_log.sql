-- Who did what (feature audit_log, on unless switched off): every new, changed or deleted stay, private, package sold, payment,
-- room charge, customer, staff member, package and product is written down with who did it (the staff member, the member in
-- their app, or the system: website, booking sites, automatic jobs), when, and for a change only the fields that changed (before
-- and after). Managers see it on each stay, private and customer (History) and for everything in Settings, Activity.
-- Kept for a year.

create table if not exists private.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  tbl text not null,
  row_id uuid,
  action text not null check (action in ('add','change','delete')),
  changes jsonb,
  staff_id uuid,
  user_id uuid,
  who text
);
create index if not exists audit_log_row on private.audit_log (tbl, row_id, at desc);
create index if not exists audit_log_at on private.audit_log (at desc);
revoke all on private.audit_log from public, anon, authenticated;

-- fields that change by themselves (totals worked out by the database) are not worth a line
create or replace function private.audit_skip() returns text[] language sql immutable as $f$
  select array['updated_at','app_paid_thb','search','tsv','last_seen','last_seen_at','unread','synced_at','mp_price','ical_seen','paid_thb','pin_hash','password','token']
$f$;

create or replace function private.audit_row() returns trigger language plpgsql security definer set search_path to '' as $f$
declare o jsonb; n jsonb; d jsonb := '{}'::jsonb; k text; sid uuid; uid uuid; w text;
begin
  if not private.feature('audit_log', true) then return null; end if;
  begin
    uid := auth.uid();
    sid := private.my_staff_id();
  exception when others then uid := null; sid := null; end;
  w := case when sid is not null then (select s.name from public.staff s where s.id = sid)
            when uid is not null then coalesce((select 'Member: ' || c.name from public.customers c where c.user_id = uid limit 1), 'Signed in user')
            else 'System (website, booking sites or automatic)' end;
  if tg_op = 'INSERT' then
    n := to_jsonb(new) - private.audit_skip();
    insert into private.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values (tg_table_name, (n->>'id')::uuid, 'add', jsonb_strip_nulls(n), sid, uid, w);
  elsif tg_op = 'UPDATE' then
    o := to_jsonb(old); n := to_jsonb(new);
    for k in select jsonb_object_keys(n) loop
      if k = any (private.audit_skip()) then continue; end if;
      if (o->k) is distinct from (n->k) then d := d || jsonb_build_object(k, jsonb_build_array(o->k, n->k)); end if;
    end loop;
    if d = '{}'::jsonb then return null; end if;
    insert into private.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values (tg_table_name, (n->>'id')::uuid, 'change', d, sid, uid, w);
  elsif tg_table_name = 'customers' then
    -- a deleted customer (for example who deleted their account) leaves no personal details in the log
    delete from private.audit_log where tbl = 'customers' and row_id = old.id;
    insert into private.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values ('customers', old.id, 'delete', '{}'::jsonb, sid, uid, w);
  else
    o := to_jsonb(old) - private.audit_skip();
    insert into private.audit_log (tbl, row_id, action, changes, staff_id, user_id, who) values (tg_table_name, (o->>'id')::uuid, 'delete', jsonb_strip_nulls(o), sid, uid, w);
  end if;
  return null;
exception when others then return null;  -- never stop the real change because of the log
end $f$;

do $p$
declare t text;
begin
  foreach t in array array['stays','privates','purchases','payments','room_charges','customers','staff','packages','shop_products','shop_orders'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('drop trigger if exists zz_audit on public.%I', t);
    execute format('create trigger zz_audit after insert or update or delete on public.%I for each row execute function private.audit_row()', t);
  end loop;
end $p$;

-- the history of one thing (a stay, a private, a customer and what belongs to them), for a manager
create or replace function public.audit_list(p_tbl text, p_row uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'tbl', a.tbl, 'action', a.action, 'changes', a.changes, 'who', a.who) order by a.at desc)
    from (select * from private.audit_log a where a.row_id = p_row and (p_tbl is null or a.tbl = p_tbl) order by a.at desc limit 200) a), '[]'::jsonb);
end $f$;
-- everything lately, for a manager: newest first, optionally one kind of thing and one person
create or replace function public.audit_recent(p_days integer default 7, p_tbl text default null, p_who text default null) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') not in ('manager','admin') then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'tbl', a.tbl, 'row_id', a.row_id, 'action', a.action, 'changes', a.changes, 'who', a.who) order by a.at desc)
    from (select * from private.audit_log a where a.at > now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 365))
            and (p_tbl is null or a.tbl = p_tbl) and (p_who is null or a.who = p_who) order by a.at desc limit 500) a), '[]'::jsonb);
end $f$;
revoke all on function public.audit_list(text, uuid), public.audit_recent(integer, text, text) from public, anon;
grant execute on function public.audit_list(text, uuid), public.audit_recent(integer, text, text) to authenticated;

do $p$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'audit-trim';
    perform cron.schedule('audit-trim', '40 3 * * *', 'delete from private.audit_log where at < now() - interval ''365 days''');
  end if;
exception when others then raise notice 'audit-trim not scheduled: %', sqlerrm;
end $p$;

notify pgrst, 'reload schema';
