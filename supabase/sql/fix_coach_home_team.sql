-- Fix: the coach and therapist home (coach_home) failed with "operator does not exist: uuid = uuid[]" where teams.sql was applied
-- before the fix. Swaps the one broken line in place; does nothing where it is already right.
do $$ declare d text; b text := 'x.id = any((select l.also_customers from public.privates l where l.id = coalesce(p.lead_id, p.id)))';
  g text := 'x.id in (select unnest(l.also_customers) from public.privates l where l.id = coalesce(p.lead_id, p.id))';
begin
  if to_regprocedure('public.coach_home()') is null then raise notice 'no coach_home, skipped'; return; end if;
  d := pg_get_functiondef('public.coach_home()'::regprocedure);
  if position(b in d) = 0 then raise notice 'coach_home already fixed'; return; end if;
  execute replace(d, b, g);
  if position(b in pg_get_functiondef('public.coach_home()'::regprocedure)) > 0 then raise exception 'coach_home fix did not apply'; end if;
end $$;
