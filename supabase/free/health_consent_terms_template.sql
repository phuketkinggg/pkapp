delete from mf.template where name like 'health_consent_terms:%';
insert into mf.template (ord, phase, kind, name, sql) values (1000801, 10, 'patch', 'health_consent_terms:1000801', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.my_consent(boolean)') is null then raise notice 'no member file here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.my_consent(boolean)'::regprocedure);
  if position('stays theirs' in d) > 0 then raise notice 'my_consent already patched'; return; end if;
  n := replace(d, $x$'In the app'$x$, $x$'In the app (terms 2: private, professional use only, the data stays theirs, never sold or used for profit)'$x$);
  if n = d then raise notice 'my_consent: older version, skipped'; return; end if;
  execute n;
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000802, 10, 'patch', 'health_consent_terms:1000802', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.member_consent_set(uuid,boolean)') is null then return; end if;
  d := pg_get_functiondef('__P__.member_consent_set(uuid,boolean)'::regprocedure);
  if position('stays theirs' in d) > 0 then raise notice 'member_consent_set already patched'; return; end if;
  n := replace(d, $x$then 'In person, recorded by ' || nm end)$x$, $x$then 'In person (terms 2: private, professional use only, the data stays theirs, never sold or used for profit), recorded by ' || nm end)$x$);
  n := replace(n, $x$consent_how = case when p_on then 'In person, recorded by ' || nm else$x$, $x$consent_how = case when p_on then 'In person (terms 2: private, professional use only, the data stays theirs, never sold or used for profit), recorded by ' || nm else$x$);
  if n = d then raise notice 'member_consent_set: older version, skipped'; return; end if;
  execute n;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'health_consent_terms:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
