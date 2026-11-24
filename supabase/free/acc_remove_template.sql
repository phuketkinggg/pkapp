delete from mf.template where name like 'acc_remove:%';
insert into mf.template (ord, phase, kind, name, sql) values (404801, 4, 'patch', 'acc_remove:404801', $TPL$create or replace function __P__.acc_payment_get(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare p __P__.payments;
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' or not __Q__.can('money') then raise exception 'Only a manager can see this.'; end if;
  select * into p from __P__.payments where id = p_id;
  if p.id is null then raise exception 'Payment not found.'; end if;
  return jsonb_build_object('id', p.id, 'day', p.day, 'at', p.at, 'amount', p.amount_thb, 'method', p.method, 'voided', p.voided, 'note', p.note,
    'customer', (select c.name from __P__.customers c where c.id = p.customer_id),
    'by', (select s.name from __P__.staff s where s.id = p.by_staff),
    'what', coalesce(
      (select k.package_name from __P__.purchases k where k.id = p.purchase_id),
      (select 'Private ' || to_char(x.date, 'DD Mon') || coalesce(', ' || nullif(x.guest_name, ''), '') || case when x.status = 'cancelled' then ' (cancelled)' else '' end from __P__.privates x where x.id = p.private_id),
      (select 'Room bill, ' || r.name from __P__.stays s join __P__.rooms r on r.id = s.room_id where s.id = p.stay_id),
      'Payment'),
    'linked', case when p.purchase_id is not null then 'package' when p.private_id is not null then 'private' when p.stay_id is not null then 'stay' end);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404802, 4, 'patch', 'acc_remove:404802', $TPL$create or replace function __P__.acc_payment_remove(p_id uuid, p_reason text) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare p __P__.payments; why text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if not __Q__.feature('acc_remove', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if coalesce(__Q__.staff_role(), '') <> 'manager' or not __Q__.can('money') then raise exception 'Only a manager can remove money from the accounts.'; end if;
  if why = '' then raise exception 'Write why it is removed.'; end if;
  select * into p from __P__.payments where id = p_id for update;
  if p.id is null then raise exception 'Payment not found.'; end if;
  if p.voided then return jsonb_build_object('ok', true, 'already', true); end if;
  if p.stripe_session is not null then raise exception 'This was paid online by card. Refund it from the customer or booking instead, so the card gets the money back.'; end if;
  update __P__.payments set voided = true,
    note = left(coalesce(nullif(note, '') || '. ', '') || 'Removed in Accounts by ' || coalesce((select name from __P__.staff where id = __Q__.my_staff_id()), 'a manager')
      || ' on ' || to_char(__Q__.bkk_today(), 'DD Mon YYYY') || ': ' || why, 1000)
  where id = p_id;
  return jsonb_build_object('ok', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198901, 11, 'patch', 'acc_remove:1198901', $TPL$revoke all on function __P__.acc_payment_get(uuid), __P__.acc_payment_remove(uuid, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198902, 11, 'patch', 'acc_remove:1198902', $TPL$grant execute on function __P__.acc_payment_get(uuid), __P__.acc_payment_remove(uuid, text) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'acc_remove:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
