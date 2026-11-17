delete from mf.template where name like 'backdated_pay:%';
insert into mf.template (ord, phase, kind, name, sql) values (403681, 4, 'patch', 'backdated_pay:403681', $TPL$create or replace function __Q__.payment_backdate() returns trigger language plpgsql security definer set search_path to '' as $f$
declare k __P__.purchases; t date := __Q__.bkk_today();
begin
  if new.purchase_id is null or new.day is distinct from t or not __Q__.feature('backdated_pay', true) then return new; end if;
  select * into k from __P__.purchases where id = new.purchase_id;
  if k.id is null or k.purchased_on is null or k.purchased_on >= t then return new; end if;
  if (k.created_at at time zone __Q__.tz())::date <> t then return new; end if;
  new.day := k.purchased_on;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197681, 11, 'patch', 'backdated_pay:1197681', $TPL$revoke all on function __Q__.payment_backdate() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901801, 9, 'patch', 'backdated_pay:901801', $TPL$drop trigger if exists payment_backdate on __P__.payments;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901802, 9, 'patch', 'backdated_pay:901802', $TPL$create trigger payment_backdate before insert on __P__.payments for each row execute function __Q__.payment_backdate();$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'backdated_pay:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
