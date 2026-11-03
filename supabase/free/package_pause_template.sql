-- Pause a package for the free gyms: adds supabase/sql/package_pause.sql to the gym template (mf.template) and to every ready gym.
delete from mf.template where name like 'package_pause:%';
insert into mf.template (ord, phase, kind, name, sql) values (300501, 3, 'alter', 'package_pause:300501', $TPL$alter table __P__.purchases add column if not exists paused_from date;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300502, 3, 'alter', 'package_pause:300502', $TPL$alter table __P__.purchases add column if not exists paused_until date;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300503, 3, 'alter', 'package_pause:300503', $TPL$alter table __P__.purchases add column if not exists pause_reason text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300504, 3, 'alter', 'package_pause:300504', $TPL$alter table __P__.purchases add column if not exists pause_ok_by text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300505, 3, 'alter', 'package_pause:300505', $TPL$alter table __P__.purchases add column if not exists paused_by uuid;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300506, 3, 'alter', 'package_pause:300506', $TPL$alter table __P__.purchases add column if not exists pause_days integer not null default 0;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300507, 3, 'alter', 'package_pause:300507', $TPL$alter table __P__.purchases add column if not exists pause_log jsonb not null default '[]'::jsonb;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400801, 4, 'function', 'package_pause:400801', $TPL$create or replace function __Q__.is_owner() returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from __P__.staff s where s.user_id = (select auth.uid()) and s.active and s.role = 'manager')
$$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400802, 4, 'function', 'package_pause:400802', $TPL$create or replace function __P__.package_pause(p_id uuid, p_from date, p_until date, p_reason text, p_ok_by text) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare p record; me uuid; d int; today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if not __Q__.feature('package_pause', true) then raise exception 'Pausing packages is turned off.'; end if;
  if not __Q__.is_owner() then raise exception 'Only the owner can pause a package.'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Say why it is paused.'; end if;
  if coalesce(btrim(p_ok_by), '') = '' then raise exception 'Say who authorised it.'; end if;
  p_from := coalesce(p_from, today);
  if p_until is not null and p_until < p_from then raise exception 'The end date is before the start date.'; end if;
  select * into p from __P__.purchases where id = p_id for update;
  if p is null then raise exception 'Package not found.'; end if;
  if p.cancelled or p.refunded_at is not null then raise exception 'This package is cancelled or refunded.'; end if;
  if p.paused_from is not null and (p.paused_until is null or p.paused_until >= today) then raise exception 'This package is already paused.'; end if;
  select id into me from __P__.staff where user_id = (select auth.uid()) and active limit 1;
  d := case when p_until is null then 0 else p_until - p_from + 1 end;
  update __P__.purchases set
    expires_on = case when expires_on is not null then expires_on + d else expires_on end,
    start_by = case when starts_on is null and start_by is not null then start_by + d else start_by end,
    paused_from = p_from, paused_until = p_until, pause_reason = btrim(p_reason), pause_ok_by = btrim(p_ok_by), paused_by = me, pause_days = d,
    pause_log = pause_log || jsonb_build_array(jsonb_build_object('pause', p_from, 'until', p_until, 'reason', btrim(p_reason), 'ok_by', btrim(p_ok_by), 'by', me, 'at', now()))
  where id = p_id;
  return jsonb_build_object('id', p_id, 'days_added', d);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400803, 4, 'function', 'package_pause:400803', $TPL$create or replace function __P__.package_resume(p_id uuid) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare p record; me uuid; real int; delta int; today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if not __Q__.is_owner() then raise exception 'Only the owner can turn a paused package back on.'; end if;
  select * into p from __P__.purchases where id = p_id for update;
  if p is null or p.paused_from is null then raise exception 'This package is not paused.'; end if;
  real := greatest(0, least(today - 1, coalesce(p.paused_until, today - 1)) - p.paused_from + 1);
  delta := real - coalesce(p.pause_days, 0);
  select id into me from __P__.staff where user_id = (select auth.uid()) and active limit 1;
  update __P__.purchases set
    expires_on = case when expires_on is not null then expires_on + delta else expires_on end,
    start_by = case when starts_on is null and start_by is not null then start_by + delta else start_by end,
    paused_from = null, paused_until = null, pause_reason = null, pause_ok_by = null, paused_by = null, pause_days = 0,
    pause_log = pause_log || jsonb_build_array(jsonb_build_object('resume', today, 'days', real, 'by', me, 'at', now()))
  where id = p_id;
  return jsonb_build_object('id', p_id, 'days_paused', real);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103401, 11, 'revoke', 'package_pause:1103401', $TPL$revoke all on function __P__.package_pause(uuid, date, date, text, text), __P__.package_resume(uuid), __Q__.is_owner() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103402, 11, 'execute', 'package_pause:1103402', $TPL$grant execute on function __P__.package_pause(uuid, date, date, text, text), __P__.package_resume(uuid), __Q__.is_owner() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (400804, 4, 'function', 'package_pause:400804', $TPL$create or replace function __Q__.checkin_not_paused() returns trigger language plpgsql security definer set search_path to '' as $f$
declare p record;
begin
  if new.purchase_id is null then return new; end if;
  select paused_from, paused_until, pause_reason into p from __P__.purchases where id = new.purchase_id;
  if p.paused_from is not null and coalesce(new.day, (now() at time zone 'Asia/Bangkok')::date) >= p.paused_from
     and (p.paused_until is null or coalesce(new.day, (now() at time zone 'Asia/Bangkok')::date) <= p.paused_until) then
    raise exception 'This package is paused%.', coalesce(': ' || p.pause_reason, '');
  end if;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900201, 9, 'trigger', 'package_pause:900201', $TPL$drop trigger if exists checkin_not_paused on __P__.checkins;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900202, 9, 'trigger', 'package_pause:900202', $TPL$create trigger checkin_not_paused before insert on __P__.checkins for each row execute function __Q__.checkin_not_paused();$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'package_pause:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';