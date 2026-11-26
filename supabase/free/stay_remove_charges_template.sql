delete from mf.template where name like 'stay_remove_charges:%';
insert into mf.template (ord, phase, kind, name, sql) values (1004201, 10, 'patch', 'stay_remove_charges:1004201', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.stay_remove(uuid)') is null or to_regclass('__P__.room_charges') is null then return; end if;
  d := pg_get_functiondef('__P__.stay_remove(uuid)'::regprocedure);
  if position('room_charges rc' in d) = 0 then
    n := replace(d, E'  -- what is on the stay with no money taken',
      E'  if exists (select 1 from __P__.room_charges rc where rc.stay_id = s.id) then\n    raise exception ''There are charges on this room bill (cafe, shop or packages). Set the stay to Cancelled instead, or move the charges first.'';\n  end if;\n  -- what is on the stay with no money taken');
    if n = d then raise notice 'stay_remove_charges: stay_remove is different, skipped'; else execute n; end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'stay_remove_charges:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
