delete from mf.template where name like 'support_access:%';
insert into mf.template (ord, phase, kind, name, sql) values (303461, 3, 'patch', 'support_access:303461', $TPL$alter table __P__.staff add column if not exists support boolean not null default false;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403581, 4, 'patch', 'support_access:403581', $TPL$create or replace function __P__.support_join() returns jsonb language plpgsql security definer set search_path to '' as $f$
declare em text := lower(coalesce(auth.jwt()->>'email', '')); uid uuid := auth.uid(); sid uuid; was_support boolean; c1 text; c2 text;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  if not __Q__.is_platform_owner() then raise exception 'Only the app support team can do this.'; end if;
  if not __Q__.feature('support_access', true) then raise exception 'This business has turned off tech support access.'; end if;
  select id, support into sid, was_support from __P__.staff where user_id = uid limit 1;
  if sid is not null and not was_support then return jsonb_build_object('ok', true, 'staff', true); end if;
  -- the staff guard only lets managers add managers: this is the system adding support, so it runs as the system
  c1 := current_setting('request.jwt.claims', true); c2 := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claims', '{}', true); perform set_config('request.jwt.claim.sub', '', true);
  if sid is not null then
    update __P__.staff set active = true, role = 'manager' where id = sid;
  else
    insert into __P__.staff (user_id, name, email, role, active, also_coach, web_show, privates_off, support)
      values (uid, 'Tech support', nullif(em, ''), 'manager', true, false, false, true, true);
    update __P__.staff set user_id = uid where support and user_id is null and lower(email) = em;
  end if;
  perform set_config('request.jwt.claims', coalesce(c1, ''), true); perform set_config('request.jwt.claim.sub', coalesce(c2, ''), true);
  return jsonb_build_object('ok', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403582, 4, 'patch', 'support_access:403582', $TPL$create or replace function __P__.support_leave() returns void language plpgsql security definer set search_path to '' as $f$
declare uid uuid := auth.uid(); c1 text := current_setting('request.jwt.claims', true); c2 text := current_setting('request.jwt.claim.sub', true);
begin
  if uid is null then return; end if;
  perform set_config('request.jwt.claims', '{}', true); perform set_config('request.jwt.claim.sub', '', true);
  delete from __P__.staff where user_id = uid and support;
  perform set_config('request.jwt.claims', coalesce(c1, ''), true); perform set_config('request.jwt.claim.sub', coalesce(c2, ''), true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403583, 4, 'patch', 'support_access:403583', $TPL$create or replace function __Q__.support_off() returns trigger language plpgsql security definer set search_path to '' as $f$
declare c1 text; c2 text;
begin
  if new.key = 'features' and not __Q__.feature('support_access', true) and exists (select 1 from __P__.staff where support) then
    c1 := current_setting('request.jwt.claims', true); c2 := current_setting('request.jwt.claim.sub', true);
    perform set_config('request.jwt.claims', '{}', true); perform set_config('request.jwt.claim.sub', '', true);
    delete from __P__.staff where support;
    perform set_config('request.jwt.claims', coalesce(c1, ''), true); perform set_config('request.jwt.claim.sub', coalesce(c2, ''), true);
  end if;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901741, 9, 'patch', 'support_access:901741', $TPL$drop trigger if exists support_off on __P__.app_settings;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901742, 9, 'patch', 'support_access:901742', $TPL$create trigger support_off after insert or update on __P__.app_settings for each row execute function __Q__.support_off();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197581, 11, 'patch', 'support_access:1197581', $TPL$revoke all on function __P__.support_join() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197582, 11, 'patch', 'support_access:1197582', $TPL$revoke all on function __P__.support_leave() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197583, 11, 'patch', 'support_access:1197583', $TPL$revoke all on function __Q__.support_off() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197584, 11, 'patch', 'support_access:1197584', $TPL$grant execute on function __P__.support_join() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197585, 11, 'patch', 'support_access:1197585', $TPL$grant execute on function __P__.support_leave() to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'support_access:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
