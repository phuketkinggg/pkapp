-- Action groups: a step can open at a time of day on its day (feature group_exercises), for example Day 3 at 18:00.
-- Without a time it opens at the start of its day, as before. Steps are kept in action_groups.items as {at_time: 'HH:MM'}.

-- is the step open now for someone who started on p_start (business time, Bangkok)
create or replace function private.step_open(p_item jsonb, p_start date) returns boolean
language plpgsql stable set search_path to '' as $f$
declare d date := private.step_on(p_item, p_start); t text := coalesce(p_item->>'at_time', '');
begin
  if d is null then return false; end if;
  if d < private.bkk_today() then return true; end if;
  if d > private.bkk_today() then return false; end if;
  if t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or not private.feature('group_exercises', true) then return true; end if;
  return (now() at time zone 'Asia/Bangkok')::time >= t::time;
end $f$;

-- what members see: steps open now, not just steps whose day has come
do $p$
declare d text; n text;
begin
  if to_regprocedure('private.group_data(uuid,boolean)') is null then raise notice 'no group_data, skipped'; return; end if;
  d := pg_get_functiondef('private.group_data(uuid,boolean)'::regprocedure);
  if position('step_open' in d) > 0 then raise notice 'group_data already patched'; return; end if;
  if position('private.step_on(it,m.start_on) <= private.bkk_today()' in d) = 0 or position('private.step_on(it,m.start_on) > private.bkk_today()' in d) = 0 then
    raise notice 'group_data: older version, skipped'; return; end if;
  n := replace(replace(d, 'private.step_on(it,m.start_on) <= private.bkk_today()', 'private.step_open(it,m.start_on)'),
    'private.step_on(it,m.start_on) > private.bkk_today()', 'not private.step_open(it,m.start_on)');
  execute n;
  if position('step_open' in pg_get_functiondef('private.group_data(uuid,boolean)'::regprocedure)) = 0 then raise exception 'group_data patch did not apply'; end if;
end $p$;

-- saving: the time must be a real time of day
do $p$
declare d text; n text; k text := 'if coalesce(x->>''at_mode'',''week'') = ''date''';
begin
  if to_regprocedure('public.group_save(jsonb)') is null then raise notice 'no group_save, skipped'; return; end if;
  d := pg_get_functiondef('public.group_save(jsonb)'::regprocedure);
  if position('at_time' in d) > 0 then raise notice 'group_save already patched'; return; end if;
  if position(k in d) = 0 then raise notice 'group_save: older version, skipped'; return; end if;
  n := replace(d, k, 'if coalesce(x->>''at_time'','''') <> '''' and x->>''at_time'' !~ ''^([01][0-9]|2[0-3]):[0-5][0-9]$'' then raise exception ''Pick a time for "%" like 18:00.'', coalesce(nullif(x->>''title'',''''),''a step''); end if;
    ' || k);
  execute n;
  if position('at_time' in pg_get_functiondef('public.group_save(jsonb)'::regprocedure)) = 0 then raise exception 'group_save patch did not apply'; end if;
end $p$;

notify pgrst, 'reload schema';
