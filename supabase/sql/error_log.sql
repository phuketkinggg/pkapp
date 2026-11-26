-- App errors (feature error_log, on by default): errors people hit in the app are kept for 30 days and listed for managers
-- in Settings, Activity, App errors. Anyone can send one (also before signing in), at most 300 an hour, so it cannot be flooded.

create table if not exists private.app_errors (
  id bigserial primary key,
  at timestamptz not null default now(),
  msg text not null,
  "where" text,
  page text,
  ver text,
  role text,
  agent text,
  user_id uuid
);
create index if not exists app_errors_at on private.app_errors (at);
revoke all on private.app_errors from public, anon, authenticated;

create or replace function public.app_error_log(p jsonb) returns void language plpgsql security definer set search_path = '' as $f$
begin
  if not private.feature('error_log', true) then return; end if;
  if (select count(*) from private.app_errors where at > now() - interval '1 hour') >= 300 then return; end if;
  insert into private.app_errors (msg, "where", page, ver, role, agent, user_id)
  values (left(coalesce(p->>'msg', ''), 500), left(p->>'where', 500), left(p->>'page', 200), left(p->>'ver', 200), left(p->>'role', 40), left(p->>'agent', 200), auth.uid());
end $f$;
revoke all on function public.app_error_log(jsonb) from public;
grant execute on function public.app_error_log(jsonb) to anon, authenticated;

create or replace function public.app_error_list(p_days int default 7) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'n')::int desc, x->>'last' desc) from (
    select jsonb_build_object('msg', e.msg, 'n', count(*), 'last', max(e.at), 'where', max(e."where"),
      'roles', string_agg(distinct nullif(e.role, ''), ', ')) x
    from private.app_errors e where e.at > now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 30))
    group by e.msg limit 50) q), '[]'::jsonb);
end $f$;
revoke all on function public.app_error_list(int) from public, anon;
grant execute on function public.app_error_list(int) to authenticated;

do $p$ declare q text := (select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = 'private.app_errors'::regclass);
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'app-errors-trim-' || q;
    perform cron.schedule('app-errors-trim-' || q, '50 3 * * *', format('delete from %I.app_errors where at < now() - interval ''30 days''', q));
  end if;
end $p$;

notify pgrst, 'reload schema';
