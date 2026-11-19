delete from mf.template where name like 'site_page_conflict:%';
insert into mf.template (ord, phase, kind, name, sql) values (1002271, 10, 'patch', 'site_page_conflict:1002271', $TPL$do $patch$
declare s text; n text;
begin
  if to_regprocedure('__P__.site_page_save(jsonb)') is null then raise notice 'site_page_conflict: no site_page_save here, skipped'; return; end if;
  s := pg_get_functiondef('__P__.site_page_save(jsonb)'::regprocedure);
  if s like '%changed in another place%' then return; end if;
  n := replace(s, $a$  else
    update __P__.site_pages set slug=s,$a$, $a$  else
    if nullif(p->>'base','') is not null and exists (select 1 from __P__.site_pages x where x.id = v_id and x.updated_at > (p->>'base')::timestamptz + interval '2 seconds') then
      raise exception 'This page was changed in another place since you opened it. Close it and open it again to get the latest copy, then make your change.';
    end if;
    update __P__.site_pages set slug=s,$a$);
  n := replace(n, $a$return jsonb_build_object('id',r.id,'slug',r.slug,'preview_token',r.preview_token,'status',r.status);$a$,
                  $a$return jsonb_build_object('id',r.id,'slug',r.slug,'preview_token',r.preview_token,'status',r.status,'updated_at',r.updated_at);$a$);
  if n not like '%changed in another place%' or n not like '%''updated_at'',r.updated_at%' then raise notice 'site_page_conflict: site_page_save is a different version here, skipped'; return; end if;
  execute n;
end $patch$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'site_page_conflict:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
