-- Muay Friend: help new free gyms get going. A gym whose app is still empty (no packages, no timetable, no members)
-- gets a friendly email on day 1, day 4 and day 10 after signing up, offering to set it up for them.
-- Sent by the edge function mf-nudge, which pg_cron calls every day at 10:00 Thai time. A gym that has started
-- using the app gets nothing. Gyms marked no_nudge (tests, family, partners) never get them.
-- Free project only (bnglnfdgptvnmugntiom).

alter table mf.gyms add column if not exists nudges jsonb not null default '{}'::jsonb;
alter table mf.gyms add column if not exists no_nudge boolean not null default false;

-- is the gym's app still empty?
create or replace function mf.gym_empty(p_schema text) returns boolean language plpgsql stable security definer set search_path to '' as $f$
declare n int;
begin
  execute format('select (select count(*) from %1$I.packages) + (select count(*) from %1$I.classes) + (select count(*) from %1$I.customers)', p_schema) into n;
  return n = 0;
exception when others then return false;
end $f$;

-- the owner's first name, from the gym's own staff list
create or replace function mf.gym_first(p_schema text, p_email text) returns text language plpgsql stable security definer set search_path to '' as $f$
declare n text;
begin
  execute format('select name from %I.staff where lower(email) = lower($1) limit 1', p_schema) into n using p_email;
  return coalesce(nullif(split_part(btrim(coalesce(n, '')), ' ', 1), ''), '');
exception when others then return '';
end $f$;

-- the gyms due an email now: step 1 from day 1, step 2 from day 4, step 3 from day 10 (each once, in order)
create or replace function public.mf_nudge_list(p_key text) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare k text := (select value #>> '{}' from mf.cfg where key = 'nudge_key');
begin
  if k is null or p_key is distinct from k then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('slug', g.slug, 'gym', g.name, 'email', g.owner_email, 'step', x.step,
      'lang', coalesce((select s.info->>'lang' from mf.signups s where s.slug = g.slug order by s.at desc limit 1), 'en'),
      'first', mf.gym_first(g.schema_pub, g.owner_email)))
    from mf.gyms g
    cross join lateral (select case
        when not (g.nudges ? '1') and g.made_at < now() - interval '1 day' then 1
        when (g.nudges ? '1') and not (g.nudges ? '2') and g.made_at < now() - interval '4 days' then 2
        when (g.nudges ? '2') and not (g.nudges ? '3') and g.made_at < now() - interval '10 days' then 3 end as step) x
    where x.step is not null and g.status = 'ready' and not g.no_nudge and g.owner_email is not null
      and g.made_at > now() - interval '30 days' and mf.gym_empty(g.schema_pub)), '[]'::jsonb);
end $f$;

create or replace function public.mf_nudge_mark(p_key text, p_slug text, p_step int, p_result text) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if p_key is distinct from (select value #>> '{}' from mf.cfg where key = 'nudge_key') then raise exception 'Not allowed.'; end if;
  update mf.gyms set nudges = nudges || jsonb_build_object(p_step::text, jsonb_build_object('at', now(), 'result', left(p_result, 200))) where slug = p_slug;
end $f$;

revoke all on function public.mf_nudge_list(text) from public, anon, authenticated;
revoke all on function public.mf_nudge_mark(text, text, int, text) from public, anon, authenticated;
revoke all on function mf.gym_empty(text) from public, anon, authenticated;
revoke all on function mf.gym_first(text, text) from public, anon, authenticated;
grant execute on function public.mf_nudge_list(text) to service_role;
grant execute on function public.mf_nudge_mark(text, text, int, text) to service_role;

-- the key the daily job uses to call the function (made once, kept in the database only)
insert into mf.cfg (key, value) select 'nudge_key', to_jsonb(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
  where not exists (select 1 from mf.cfg where key = 'nudge_key');

-- every day at 10:00 Thai time (03:00 UTC)
select cron.unschedule('mf-nudge') where exists (select 1 from cron.job where jobname = 'mf-nudge');
select cron.schedule('mf-nudge', '0 3 * * *', $c$
  select net.http_post(url := 'https://bnglnfdgptvnmugntiom.supabase.co/functions/v1/mf-nudge',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-key', (select value #>> '{}' from mf.cfg where key = 'nudge_key')),
    body := '{}'::jsonb)
$c$);
