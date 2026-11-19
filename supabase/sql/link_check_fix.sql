-- Fix: saving the gym tour and room 360 photos failed with "invalid regular expression: invalid repetition count(s)".
-- The link check used {1,400}, but the database allows at most 255 repeats. It now uses + (any length).
-- Patch: checks it applied, skips cleanly where the functions are missing or already fixed.
do $patch$
declare f text; s text; n text;
begin
  foreach f in array array['public.site_tour_save(jsonb)', 'public.room_360_save(jsonb)'] loop
    if to_regprocedure(f) is null then raise notice 'link_check_fix: % not here, skipped', f; continue; end if;
    s := pg_get_functiondef(f::regprocedure);
    if position('{1,400}' in s) = 0 then continue; end if;
    n := replace(s, '[^"<>\s]{1,400}$', '[^"<>\s]+$');
    if position('{1,400}' in n) > 0 then raise exception 'link_check_fix: % did not change', f; end if;
    execute n;
  end loop;
end $patch$;
