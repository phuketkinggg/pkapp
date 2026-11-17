delete from mf.template where name like 'signups_own_gym:%';
insert into mf.template (ord, phase, kind, name, sql) values (1002241, 10, 'patch', 'signups_own_gym:1002241', $TPL$do $p$
declare d text; a text := 'where u.created_at > now() - interval ''60 days'' and u.email is not null and u.deleted_at is null';
begin
  if to_regprocedure('__P__.app_signups_pending()') is null then raise notice 'app_signups_pending: not here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.app_signups_pending()'::regprocedure);
  if position('mf.gyms' in d) > 0 then raise notice 'app_signups_pending: already own gym only'; return; end if;
  if position(a in d) = 0 then raise exception 'app_signups_pending: a different version, not patched'; end if;
  execute replace(d, a, a || ' and lower(coalesce(u.raw_user_meta_data->>''gym'', '''')) in (select g.slug from mf.gyms g where g.schema_pub = ''__P__'')');
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002242, 10, 'patch', 'signups_own_gym:1002242', $TPL$do $p$
declare d text; a text := '  if u.id is null then raise exception ''That sign-up was not found.''; end if;';
begin
  if to_regprocedure('__P__.app_signup_finish(uuid,text,text)') is null then raise notice 'app_signup_finish: not here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.app_signup_finish(uuid,text,text)'::regprocedure);
  if position('mf.gyms' in d) > 0 then raise notice 'app_signup_finish: already own gym only'; return; end if;
  if position(a in d) = 0 then raise exception 'app_signup_finish: a different version, not patched'; end if;
  execute replace(d, a, a || E'\n  if lower(coalesce(u.raw_user_meta_data->>''gym'', '''')) not in (select g.slug from mf.gyms g where g.schema_pub = ''__P__'') then raise exception ''That sign-up was not found.''; end if;');
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'signups_own_gym:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
