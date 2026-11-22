delete from mf.template where name like 'brief_choice:%';
insert into mf.template (ord, phase, kind, name, sql) values (404501, 4, 'patch', 'brief_choice:404501', $TPL$create or replace function __Q__.brief_wants(p_staff uuid, p_role text) returns boolean language sql stable security definer set search_path = '' as $f$
  select p_role in ('coach','manager') and not coalesce(((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'booking_push')->'brief_off') ? p_staff::text, false)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404502, 4, 'patch', 'brief_choice:404502', $TPL$create or replace function __P__.brief_notify_mine() returns boolean language sql stable security definer set search_path = '' as $f$
  select __Q__.brief_wants(__Q__.my_staff_id(), __Q__.staff_role())
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404503, 4, 'patch', 'brief_choice:404503', $TPL$create or replace function __P__.brief_notify_set(p_on boolean) returns boolean language plpgsql security definer set search_path = '' as $f$
declare me uuid := __Q__.my_staff_id(); c jsonb; l jsonb;
begin
  if me is null or coalesce(__Q__.staff_role(), '') not in ('coach','manager') then raise exception 'Only coaches and managers get this notice.'; end if;
  c := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'booking_push'), '{}'::jsonb);
  l := coalesce((select jsonb_agg(x) from jsonb_array_elements_text(coalesce(c->'brief_off', '[]'::jsonb)) x where x <> me::text), '[]'::jsonb);
  if not p_on then l := l || jsonb_build_array(me::text); end if;
  c := jsonb_set(c, '{brief_off}', l);
  insert into __P__.app_settings(key, value) values ('booking_push', c::text) on conflict (key) do update set value = excluded.value;
  return p_on;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198601, 11, 'patch', 'brief_choice:1198601', $TPL$revoke all on function __P__.brief_notify_mine(), __P__.brief_notify_set(boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198602, 11, 'patch', 'brief_choice:1198602', $TPL$grant execute on function __P__.brief_notify_mine(), __P__.brief_notify_set(boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404504, 4, 'patch', 'brief_choice:404504', $TPL$create or replace function __Q__.brief_push(p_day date default null) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare d date := coalesce(p_day, __Q__.bkk_today() + 1); g jsonb; n int; body text;
begin
  if not __Q__.feature('brief_push', true) then return null; end if;
  g := __P__.coach_brief(d)->'guests';
  n := coalesce(jsonb_array_length(g), 0);
  if n = 0 then return null; end if;
  select string_agg(
      split_part(x->>'name', ' ', 1)
      || case when coalesce(x->>'room', '') <> '' then ', staying in the resort (' || (x->>'room') || ')' else '' end
      || coalesce(', wants ' || lower(nullif(coalesce(
           case x->'answers'->>'main' when 'fight' then 'serious fight training' when 'weight' then 'to lose weight' when 'fitness' then 'to get fit'
             when 'technique' then 'to learn Muay Thai' when 'reset' then 'to reset and recharge' when 'other' then x->'answers'->>'main_other' end,
           x->'answers'->>'win'), '')), ''),
      '. ' order by x->>'name') || '.'
    into body from jsonb_array_elements(g) x;
  return jsonb_build_object(
    'title', 'รู้จักนักเรียน / Know your students: ' || case when n = 1 then 'a new student arrives tomorrow' else n || ' new students arrive tomorrow' end,
    'body', left(body, 300),
    'tag', 'brief-' || d, 'url', '#arriving',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from __P__.push_subs s join __P__.staff st on st.id = s.staff_id where s.off_at is null and st.active and __Q__.brief_wants(st.id, st.role)), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003101, 10, 'patch', 'brief_choice:1003101', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.my_push_kinds()') is not null then
    d := pg_get_functiondef('__P__.my_push_kinds()'::regprocedure);
    if position('brief_wants' in d) = 0 then
      n := replace(d, '      when (c->''roles'') ? r then c->''kinds'' else ''[]''::jsonb end);',
        '      when (c->''roles'') ? r then c->''kinds'' else ''[]''::jsonb end
      || case when __Q__.brief_wants(me, r) then ''["brief"]''::jsonb else ''[]''::jsonb end);');
      if n = d then raise notice 'brief_choice: my_push_kinds is different, skipped'; else execute n; end if;
    end if;
  end if;
  if to_regprocedure('__P__.my_push_kinds_save(jsonb)') is not null then
    d := pg_get_functiondef('__P__.my_push_kinds_save(jsonb)'::regprocedure);
    if position('brief_notify_set' in d) = 0 then
      n := replace(d, '  if not __Q__.feature(''notify_choice'', true) then raise exception ''Switched off in Settings, Features.''; end if;',
        '  if not __Q__.feature(''notify_choice'', true) then raise exception ''Switched off in Settings, Features.''; end if;
  if coalesce(__Q__.staff_role(), '''') in (''coach'',''manager'') then perform __P__.brief_notify_set(p_kinds is null or coalesce(p_kinds ? ''brief'', false)); end if;');
      if n = d then raise notice 'brief_choice: my_push_kinds_save is different, skipped'; else execute n; end if;
    end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'brief_choice:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
