-- Ask AI can do anything the person can do in the app (feature ask_ai_all, on unless switched off): besides its own actions it may
-- call any of the app's database functions the person may run, and add, change or remove rows they may change. It always runs
-- with the person's own rights and nothing happens before they tap Confirm. Functions that handle codes, passwords, tokens or
-- delete accounts are never offered.

create or replace function public.ai_functions() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('name', p.proname, 'args', pg_get_function_arguments(p.oid), 'returns', pg_get_function_result(p.oid),
      'about', obj_description(p.oid, 'pg_proc')) order by p.proname), '[]'::jsonb)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.oid = (select x.pronamespace from pg_proc x where x.oid = 'public.ai_functions()'::regprocedure) and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
    and has_function_privilege('authenticated', p.oid, 'execute')
    and p.proname !~ '(token|secret|password|passw|_pin|pin_|delete_me|desk_code|^ai_|platform|plat_|backup|webhook|_hook|crypt|sync_)'
    and private.my_staff_id() is not null
$f$;
revoke all on function public.ai_functions() from public, anon;
grant execute on function public.ai_functions() to authenticated;

notify pgrst, 'reload schema';
