-- stay_guests.sql for the free app: the template rows of the two functions get the same change, then every ready gym gets it.
delete from mf.template where name like 'stay_guests:%';
insert into mf.template (ord, phase, kind, name, sql) values (300611, 3, 'patch', 'stay_guests:300611', $TPL$alter table __P__.stays add column if not exists guest_names text;$TPL$);
update mf.template set sql = replace(replace(regexp_replace(sql,
    'select s\.id into v_stay from __P__\.stays s\s+where s\.customer_id = new\.customer_id',
    'if new.for_stay is not null then select s.id into v_stay from __P__.stays s where s.id = new.for_stay and s.status in (''booked'',''in'') and not s.settled; if v_stay is null then raise exception ''That stay is closed or settled, so it cannot go on its room bill.''; end if; end if; if v_stay is null then select s.id into v_stay from __P__.stays s where s.customer_id = new.customer_id'),
    'order by s.check_in desc limit 1;', 'order by s.check_in desc limit 1; end if;'),
    'values (v_stay, new.package_name, new.price_thb',
    'values (v_stay, new.package_name || coalesce((select '', for '' || c.name from __P__.customers c join __P__.stays s2 on s2.id = v_stay where c.id = new.customer_id and s2.customer_id is distinct from new.customer_id), ''''), new.price_thb')
  where name = 'private.charge_purchase_to_room' and sql like 'CREATE OR REPLACE FUNCTION%' and position('new.for_stay' in sql) = 0;
update mf.template set sql = regexp_replace(sql, 'begin\s+amt :=', 'begin' || E'\n  if new.method = ''room'' then return null; end if;\n  amt :=')
  where name = 'private.purchase_paid_now' and sql like 'CREATE OR REPLACE FUNCTION%' and position('''room''' in sql) = 0;
do $$ declare g record; r record; begin
  if (select count(*) from mf.template where name in ('private.charge_purchase_to_room','private.purchase_paid_now') and sql like 'CREATE OR REPLACE FUNCTION%' and (position('new.for_stay' in sql) > 0 or position('''room''' in sql) > 0)) <> 2 then
    raise exception 'stay_guests: template patch did not apply'; end if;
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'stay_guests:%' or (name in ('private.charge_purchase_to_room','private.purchase_paid_now') and sql like 'CREATE OR REPLACE FUNCTION%') order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
