-- Start in easy steps (feature onboard_steps): every new gym starts at step 1 (check ins) and moves on when it is ready.
-- The Muay Friend dashboard shows which step each gym is on.

do $p$
declare d text; n text;
begin
  d := pg_get_functiondef('mf.make_gym(text,text,text,uuid,text,text)'::regprocedure);
  if position('''onboard''' in d) > 0 then raise notice 'make_gym already starts new gyms in steps'; return; end if;
  n := replace(d, '(''review_message'', %L), (''plan'', %L)', '(''review_message'', %L), (''plan'', %L), (''onboard'', ''{"path":"gym","step":1}'')');
  if n = d then raise exception 'make_gym did not change: check the settings insert'; end if;
  execute n;
end $p$;

-- the team: which step each gym is on (empty: everything is on)
create or replace function public.mf_gym_steps() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare g record; v text; out jsonb := '{}';
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can see this.'; end if;
  for g in select * from mf.gyms where status = 'ready' loop
    begin
      execute format('select value from %I.app_settings where key = ''onboard''', g.schema_pub) into v;
      if v is not null and v ~ '^\s*\{' then out := out || jsonb_build_object(g.slug, v::jsonb); end if;
    exception when others then null;
    end;
  end loop;
  return out;
end $f$;
revoke all on function public.mf_gym_steps() from public, anon;
grant execute on function public.mf_gym_steps() to authenticated;

notify pgrst, 'reload schema';
