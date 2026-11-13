delete from mf.template where name like 'private_cancel:%';
insert into mf.template (ord, phase, kind, name, sql) values (302401, 3, 'patch', 'private_cancel:302401', $TPL$alter table __P__.privates add column if not exists cancel_kind text check (cancel_kind in ('cancelled','no_show'));$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302402, 3, 'patch', 'private_cancel:302402', $TPL$alter table __P__.privates add column if not exists cancel_reason text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302403, 3, 'patch', 'private_cancel:302403', $TPL$alter table __P__.privates add column if not exists cancel_charged boolean;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302404, 3, 'patch', 'private_cancel:302404', $TPL$alter table __P__.privates add column if not exists cancelled_at timestamptz;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302405, 3, 'patch', 'private_cancel:302405', $TPL$alter table __P__.privates add column if not exists cancelled_by uuid;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196501, 11, 'patch', 'private_cancel:1196501', $TPL$grant select (cancel_kind, cancel_reason, cancel_charged, cancelled_at, cancelled_by) on __P__.privates to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402501, 4, 'patch', 'private_cancel:402501', $TPL$create or replace function __P__.private_cancel(p_id uuid, p_kind text, p_reason text, p_charged boolean) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare p __P__.privates; why text := left(btrim(coalesce(p_reason, '')), 300); n int; had_paid int;
begin
  if not __Q__.feature('private_cancel', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not __Q__.is_desk() then raise exception 'Only the front desk or a manager can do this.'; end if;
  if p_kind not in ('cancelled','no_show') then raise exception 'Choose cancelled or no show.'; end if;
  if why = '' then raise exception 'Say why.'; end if;
  select * into p from __P__.privates where id = p_id for update;
  if p.id is null then raise exception 'That private was not found.'; end if;
  if p.lead_id is not null then select * into p from __P__.privates where id = p.lead_id for update; end if;
  if p.status in ('requested') then raise exception 'This one is still a request. Decline it instead.'; end if;
  if p.status = 'cancelled' and p.cancel_kind is null then raise exception 'It is already cancelled.'; end if;
  had_paid := case when p.paid and p.purchase_id is null and not coalesce(p_charged, false) then coalesce(p.price_thb, 0) else 0 end;
  update __P__.privates set
      status = case when coalesce(p_charged, false) then 'done' else 'cancelled' end,
      cancel_kind = p_kind, cancel_reason = why, cancel_charged = coalesce(p_charged, false), cancelled_at = now(), cancelled_by = __Q__.my_staff_id()
    where id = p.id or lead_id = p.id;
  get diagnostics n = row_count;
  return jsonb_build_object('rows', n, 'charged', coalesce(p_charged, false), 'paid_before', had_paid);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196502, 11, 'patch', 'private_cancel:1196502', $TPL$revoke all on function __P__.private_cancel(uuid, text, text, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196503, 11, 'patch', 'private_cancel:1196503', $TPL$grant execute on function __P__.private_cancel(uuid, text, text, boolean) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'private_cancel:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
