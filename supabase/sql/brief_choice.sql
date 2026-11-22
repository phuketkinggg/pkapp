-- Know your students (feature brief_push): each coach and manager turns the evening notice on or off for themselves,
-- in My notifications or on Coaching, Arriving soon. One notice a day, worded for coaches: who arrives, if they stay at the resort, what they want.

-- who said no: app_settings booking_push.brief_off = [staff ids]
create or replace function private.brief_wants(p_staff uuid, p_role text) returns boolean language sql stable security definer set search_path = '' as $f$
  select p_role in ('coach','manager') and not coalesce(((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'booking_push')->'brief_off') ? p_staff::text, false)
$f$;

create or replace function public.brief_notify_mine() returns boolean language sql stable security definer set search_path = '' as $f$
  select private.brief_wants(private.my_staff_id(), private.staff_role())
$f$;

create or replace function public.brief_notify_set(p_on boolean) returns boolean language plpgsql security definer set search_path = '' as $f$
declare me uuid := private.my_staff_id(); c jsonb; l jsonb;
begin
  if me is null or coalesce(private.staff_role(), '') not in ('coach','manager') then raise exception 'Only coaches and managers get this notice.'; end if;
  c := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'booking_push'), '{}'::jsonb);
  l := coalesce((select jsonb_agg(x) from jsonb_array_elements_text(coalesce(c->'brief_off', '[]'::jsonb)) x where x <> me::text), '[]'::jsonb);
  if not p_on then l := l || jsonb_build_array(me::text); end if;
  c := jsonb_set(c, '{brief_off}', l);
  insert into public.app_settings(key, value) values ('booking_push', c::text) on conflict (key) do update set value = excluded.value;
  return p_on;
end $f$;
revoke all on function public.brief_notify_mine(), public.brief_notify_set(boolean) from public, anon;
grant execute on function public.brief_notify_mine(), public.brief_notify_set(boolean) to authenticated;

-- the notice: one a day, for everyone who wants it
create or replace function private.brief_push(p_day date default null) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare d date := coalesce(p_day, private.bkk_today() + 1); g jsonb; n int; body text;
begin
  if not private.feature('brief_push', true) then return null; end if;
  g := public.coach_brief(d)->'guests';
  n := coalesce(jsonb_array_length(g), 0);
  if n = 0 then return null; end if;
  select string_agg(
      split_part(x->>'name', ' ', 1)
      || case when coalesce(x->>'room', '') <> '' then ', staying in the resort (' || (x->>'room') || ')' else '' end
      || coalesce(', wants ' || (nullif(coalesce(
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
      from public.push_subs s join public.staff st on st.id = s.staff_id where s.off_at is null and st.active and private.brief_wants(st.id, st.role)), '[]'::jsonb));
end $f$;

-- My notifications shows it as a tick box for coaches and managers
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.my_push_kinds()') is not null then
    d := pg_get_functiondef('public.my_push_kinds()'::regprocedure);
    if position('brief_wants' in d) = 0 then
      n := replace(d, '      when (c->''roles'') ? r then c->''kinds'' else ''[]''::jsonb end);',
        '      when (c->''roles'') ? r then c->''kinds'' else ''[]''::jsonb end
      || case when private.brief_wants(me, r) then ''["brief"]''::jsonb else ''[]''::jsonb end);');
      if n = d then raise notice 'brief_choice: my_push_kinds is different, skipped'; else execute n; end if;
    end if;
  end if;
  if to_regprocedure('public.my_push_kinds_save(jsonb)') is not null then
    d := pg_get_functiondef('public.my_push_kinds_save(jsonb)'::regprocedure);
    if position('brief_notify_set' in d) = 0 then
      n := replace(d, '  if not private.feature(''notify_choice'', true) then raise exception ''Switched off in Settings, Features.''; end if;',
        '  if not private.feature(''notify_choice'', true) then raise exception ''Switched off in Settings, Features.''; end if;
  if coalesce(private.staff_role(), '''') in (''coach'',''manager'') then perform public.brief_notify_set(p_kinds is null or coalesce(p_kinds ? ''brief'', false)); end if;');
      if n = d then raise notice 'brief_choice: my_push_kinds_save is different, skipped'; else execute n; end if;
    end if;
  end if;
end $p$;
