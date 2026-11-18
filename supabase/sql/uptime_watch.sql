-- Uptime watchdog: every 5 minutes this database checks that another project's app server answers (the REST API, the part the apps use).
-- Two failed checks in a row: the uptime-alert function of that project emails the business. When it answers again: one more email.
-- Runs from a different project than the one it watches, so it still works when the watched one has trouble.
-- Set up with: select private.uptime_watch_add('<project ref>', '<publishable key>');
create table if not exists private.uptime_watch (
  ref text primary key,
  apikey text not null,
  last_req bigint,
  fails int not null default 0,
  alerted boolean not null default false,
  checked_at timestamptz,
  last_status text
);
revoke all on private.uptime_watch from public, anon, authenticated;

create or replace function private.uptime_watch_add(p_ref text, p_key text) returns void language sql security definer set search_path to '' as $f$
  insert into private.uptime_watch (ref, apikey) values (p_ref, p_key) on conflict (ref) do update set apikey = excluded.apikey
$f$;
revoke all on function private.uptime_watch_add(text, text) from public, anon, authenticated;

create or replace function private.uptime_watch_run() returns void language plpgsql security definer set search_path to '' as $f$
declare w private.uptime_watch; r record; ok boolean; st text;
begin
  for w in select * from private.uptime_watch loop
    -- the answer to the check sent 5 minutes ago
    if w.last_req is not null then
      select status_code, timed_out, error_msg into r from net._http_response where id = w.last_req;
      if found then
        ok := r.status_code between 200 and 499 and r.status_code <> 408;
        st := coalesce(r.status_code::text, case when r.timed_out then 'timed out' else coalesce(left(r.error_msg, 80), 'no answer') end);
      else ok := false; st := 'no answer';
      end if;
      if ok then
        if w.alerted then
          perform net.http_post(url := 'https://' || w.ref || '.supabase.co/functions/v1/uptime-alert', headers := '{"Content-Type":"application/json"}'::jsonb,
            body := jsonb_build_object('what', 'up', 'detail', 'Checked at ' || to_char(now() at time zone 'Asia/Bangkok', 'HH24:MI DD Mon') || ' (Thailand time).'));
        end if;
        update private.uptime_watch set fails = 0, alerted = false, checked_at = now(), last_status = st where ref = w.ref;
      else
        update private.uptime_watch set fails = fails + 1, checked_at = now(), last_status = st where ref = w.ref;
        if w.fails + 1 >= 2 and not w.alerted then
          perform net.http_post(url := 'https://' || w.ref || '.supabase.co/functions/v1/uptime-alert', headers := '{"Content-Type":"application/json"}'::jsonb,
            body := jsonb_build_object('what', 'down', 'detail', 'Last answer: ' || st || ', at ' || to_char(now() at time zone 'Asia/Bangkok', 'HH24:MI DD Mon') || ' (Thailand time).'));
          update private.uptime_watch set alerted = true where ref = w.ref;
        end if;
      end if;
    end if;
    -- the next check: an ordinary read the apps do, with the public key
    update private.uptime_watch set last_req = net.http_post(url := 'https://' || w.ref || '.supabase.co/rest/v1/rpc/room_360',
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', w.apikey), body := '{}'::jsonb, timeout_milliseconds := 20000) where ref = w.ref;
  end loop;
end $f$;
revoke all on function private.uptime_watch_run() from public, anon, authenticated;

do $c$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'uptime-watch';
    perform cron.schedule('uptime-watch', '*/5 * * * *', 'select private.uptime_watch_run()');
  end if;
end $c$;
