delete from mf.template where name like 'file_views_member:%';
insert into mf.template (ord, phase, kind, name, sql) values (1001001, 10, 'patch', 'file_views_member:1001001', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.my_file()') is null then raise notice 'no member file here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.my_file()'::regprocedure);
  if position('member_file_views' in d) > 0 then raise notice 'my_file already patched'; return; end if;
  n := replace(d, $x$'coaches', coalesce((select jsonb_agg(s.name order by s.name) from __P__.coach_clients cc join __P__.staff s on s.id = cc.staff_id where cc.customer_id = cid), '[]'::jsonb));$x$,
    $x$'coaches', coalesce((select jsonb_agg(s.name order by s.name) from __P__.coach_clients cc join __P__.staff s on s.id = cc.staff_id where cc.customer_id = cid), '[]'::jsonb),
    'views', case when __Q__.feature('file_views_member', true) then coalesce((select jsonb_agg(jsonb_build_object('at', v.at, 'by', coalesce(s.name, 'A former team member')) order by v.at desc)
      from (select * from __P__.member_file_views where customer_id = cid order by at desc limit 30) v left join __P__.staff s on s.id = v.staff_id), '[]'::jsonb) end);$x$);
  if n = d then raise notice 'my_file: older version, skipped'; return; end if;
  execute n;
  if position('member_file_views' in pg_get_functiondef('__P__.my_file()'::regprocedure)) = 0 then raise exception 'my_file patch did not apply'; end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'file_views_member:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
