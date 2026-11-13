delete from mf.template where name like 'ai_power:%';
insert into mf.template (ord, phase, kind, name, sql) values (403301, 4, 'patch', 'ai_power:403301', $TPL$create or replace function __P__.ai_functions() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('name', p.proname, 'args', pg_get_function_arguments(p.oid), 'returns', pg_get_function_result(p.oid),
      'about', obj_description(p.oid, 'pg_proc')) order by p.proname), '[]'::jsonb)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.oid = (select x.pronamespace from pg_proc x where x.oid = '__P__.ai_functions()'::regprocedure) and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
    and has_function_privilege('authenticated', p.oid, 'execute')
    and p.proname !~ '(token|secret|password|passw|_pin|pin_|delete_me|desk_code|^ai_|platform|plat_|backup|webhook|_hook|crypt|sync_)'
    and __Q__.my_staff_id() is not null
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197301, 11, 'patch', 'ai_power:1197301', $TPL$revoke all on function __P__.ai_functions() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197302, 11, 'patch', 'ai_power:1197302', $TPL$grant execute on function __P__.ai_functions() to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'ai_power:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
