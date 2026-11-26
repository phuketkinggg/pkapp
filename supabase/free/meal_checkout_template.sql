delete from mf.template where name like 'meal_checkout:%';
insert into mf.template (ord, phase, kind, name, sql) values (405201, 4, 'patch', 'meal_checkout:405201', $TPL$create or replace function __Q__.meal_to_checkout() returns trigger language plpgsql security definer set search_path = '' as $f$
declare co date;
begin
  if new.covers is distinct from array['Cafe meal'] or coalesce(new.stay_id, new.for_stay) is null or new.expires_on is null then return new; end if;
  if not __Q__.feature('meal_checkout', true) then return new; end if;
  select s.check_out into co from __P__.stays s where s.id = coalesce(new.stay_id, new.for_stay);
  if co is not null and new.expires_on = co - 1 then new.expires_on := co; end if;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199301, 11, 'patch', 'meal_checkout:1199301', $TPL$revoke all on function __Q__.meal_to_checkout() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903401, 9, 'patch', 'meal_checkout:903401', $TPL$drop trigger if exists purchases_meal_checkout on __P__.purchases;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903402, 9, 'patch', 'meal_checkout:903402', $TPL$create trigger purchases_meal_checkout before insert or update of expires_on, stay_id, for_stay on __P__.purchases
  for each row execute function __Q__.meal_to_checkout();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003801, 10, 'patch', 'meal_checkout:1003801', $TPL$update __P__.purchases k set expires_on = s.check_out
from __P__.stays s
where s.id = coalesce(k.stay_id, k.for_stay) and k.covers = array['Cafe meal'] and not coalesce(k.cancelled, false)
  and k.expires_on = s.check_out - 1 and s.check_out >= __Q__.bkk_today() and __Q__.feature('meal_checkout', true);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003802, 10, 'patch', 'meal_checkout:1003802', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.meal_plans_today()') is null then return; end if;
  d := pg_get_functiondef('__P__.meal_plans_today()'::regprocedure);
  if position('''from'', k.starts_on' in d) = 0 then
    n := replace(d, '''until'', k.expires_on,', '''until'', k.expires_on, ''from'', k.starts_on,
      ''leaves'', (select s.check_out from __P__.stays s where s.id = coalesce(k.stay_id, k.for_stay)),');
    if n = d then raise notice 'meal_checkout: meal_plans_today is different, skipped'; else execute n; end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'meal_checkout:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
