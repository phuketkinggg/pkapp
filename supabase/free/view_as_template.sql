delete from mf.template where name like 'view_as:%';
insert into mf.template (ord, phase, kind, name, sql) values (406201, 4, 'patch', 'view_as:406201', $TPL$create or replace function __P__.staff_view_list() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if not exists (select 1 from __P__.staff s where s.user_id = auth.uid() and s.active and s.role = 'manager') then raise exception 'Only a manager can do this.'; end if;
  if not __Q__.feature('view_as', true) then raise exception 'Switched off in Settings, Features.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', s.role) order by s.role, s.name)
    from __P__.staff s where s.active and s.user_id is not null and s.user_id <> auth.uid()), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199981, 11, 'patch', 'view_as:1199981', $TPL$revoke all on function __P__.staff_view_list() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199982, 11, 'patch', 'view_as:1199982', $TPL$grant execute on function __P__.staff_view_list() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406202, 4, 'patch', 'view_as:406202', $TPL$create or replace function __P__.staff_view_as(p_staff uuid, p_fn text, p_args jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $f$
declare t __P__.staff; f record; call text; res jsonb; old_c text := current_setting('request.jwt.claims', true);
  old_s text := current_setting('request.jwt.claim.sub', true); k text; v text; parts text[] := '{}';
  sch text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = '__P__.staff'::regclass);
begin
  if not exists (select 1 from __P__.staff s where s.user_id = auth.uid() and s.active and s.role = 'manager') then raise exception 'Only a manager can do this.'; end if;
  if not __Q__.feature('view_as', true) then raise exception 'Switched off in Settings, Features.'; end if;
  select * into t from __P__.staff where id = p_staff and active;
  if t.id is null or t.user_id is null then raise exception 'This person has no login.'; end if;
  if coalesce(p_fn, '') !~ '^[a-z_][a-z0-9_]{0,62}$' or p_fn in ('staff_view_as', 'staff_view_list') then raise exception 'Not allowed.'; end if;
  -- only functions that read, and only ones written for the app (security definer, open to signed in people)
  select p.oid, p.proretset into f from pg_proc p where p.pronamespace = sch::regnamespace and p.proname = p_fn
    and p.provolatile in ('s', 'i') and p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute') limit 1;
  if f.oid is null then raise exception 'Viewing only: changes are off while you view as someone else.'; end if;
  for k, v in select * from jsonb_each_text(coalesce(p_args, '{}'::jsonb)) loop
    if k !~ '^[a-z_][a-z0-9_]{0,62}$' then raise exception 'Not allowed.'; end if;
    parts := parts || format('%I => %s', k, coalesce(quote_literal(v), 'null'));
  end loop;
  call := format('%I.%I(%s)', sch, p_fn, array_to_string(parts, ', '));
  perform set_config('request.jwt.claims', (coalesce(nullif(old_c, ''), '{}')::jsonb || jsonb_build_object('sub', t.user_id))::text, true);
  perform set_config('request.jwt.claim.sub', t.user_id::text, true);
  begin
    if f.proretset then execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from %s x', call) into res;
    else execute format('select to_jsonb(%s)', call) into res; end if;
  exception when others then
    perform set_config('request.jwt.claims', coalesce(old_c, ''), true); perform set_config('request.jwt.claim.sub', coalesce(old_s, ''), true);
    raise;
  end;
  perform set_config('request.jwt.claims', coalesce(old_c, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(old_s, ''), true);
  return res;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199983, 11, 'patch', 'view_as:1199983', $TPL$revoke all on function __P__.staff_view_as(uuid, text, jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199984, 11, 'patch', 'view_as:1199984', $TPL$grant execute on function __P__.staff_view_as(uuid, text, jsonb) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'view_as:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
