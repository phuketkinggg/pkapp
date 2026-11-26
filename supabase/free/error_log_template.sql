delete from mf.template where name like 'error_log:%';
insert into mf.template (ord, phase, kind, name, sql) values (306001, 3, 'patch', 'error_log:306001', $TPL$create table if not exists __Q__.app_errors (
  id bigserial primary key,
  at timestamptz not null default now(),
  msg text not null,
  "where" text,
  page text,
  ver text,
  role text,
  agent text,
  user_id uuid
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004601, 10, 'patch', 'error_log:1004601', $TPL$create index if not exists app_errors_at on __Q__.app_errors (at);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199961, 11, 'patch', 'error_log:1199961', $TPL$revoke all on __Q__.app_errors from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406001, 4, 'patch', 'error_log:406001', $TPL$create or replace function __P__.app_error_log(p jsonb) returns void language plpgsql security definer set search_path = '' as $f$
begin
  if not __Q__.feature('error_log', true) then return; end if;
  if (select count(*) from __Q__.app_errors where at > now() - interval '1 hour') >= 300 then return; end if;
  insert into __Q__.app_errors (msg, "where", page, ver, role, agent, user_id)
  values (left(coalesce(p->>'msg', ''), 500), left(p->>'where', 500), left(p->>'page', 200), left(p->>'ver', 200), left(p->>'role', 40), left(p->>'agent', 200), auth.uid());
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199962, 11, 'patch', 'error_log:1199962', $TPL$revoke all on function __P__.app_error_log(jsonb) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199963, 11, 'patch', 'error_log:1199963', $TPL$grant execute on function __P__.app_error_log(jsonb) to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (406002, 4, 'patch', 'error_log:406002', $TPL$create or replace function __P__.app_error_list(p_days int default 7) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'n')::int desc, x->>'last' desc) from (
    select jsonb_build_object('msg', e.msg, 'n', count(*), 'last', max(e.at), 'where', max(e."where"),
      'roles', string_agg(distinct nullif(e.role, ''), ', ')) x
    from __Q__.app_errors e where e.at > now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 30))
    group by e.msg limit 50) q), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199964, 11, 'patch', 'error_log:1199964', $TPL$revoke all on function __P__.app_error_list(int) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199965, 11, 'patch', 'error_log:1199965', $TPL$grant execute on function __P__.app_error_list(int) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004602, 10, 'patch', 'error_log:1004602', $TPL$do $p$ declare q text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = '__Q__.app_errors'::regclass);
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'app-errors-trim-' || q;
    perform cron.schedule('app-errors-trim-' || q, '50 3 * * *', format('delete from %I.app_errors where at < now() - interval ''30 days''', q));
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'error_log:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
