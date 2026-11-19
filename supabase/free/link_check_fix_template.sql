delete from mf.template where name like 'link_check_fix:%';
insert into mf.template (ord, phase, kind, name, sql) values (1002281, 10, 'patch', 'link_check_fix:1002281', $TPL$do $patch$
declare f text; s text; n text;
begin
  foreach f in array array['__P__.site_tour_save(jsonb)', '__P__.room_360_save(jsonb)'] loop
    if to_regprocedure(f) is null then raise notice 'link_check_fix: % not here, skipped', f; continue; end if;
    s := pg_get_functiondef(f::regprocedure);
    if position('{1,400}' in s) = 0 then continue; end if;
    n := replace(s, '[^"<>\s]{1,400}$', '[^"<>\s]+$');
    if position('{1,400}' in n) > 0 then raise exception 'link_check_fix: % did not change', f; end if;
    execute n;
  end loop;
end $patch$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'link_check_fix:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
