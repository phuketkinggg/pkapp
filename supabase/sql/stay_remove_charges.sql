-- Deleting a stay with charges on its room bill (cafe, shop, packages charged to the room) is refused:
-- the charges would be lost. Set it to Cancelled instead, or move the charges first.
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.stay_remove(uuid)') is null or to_regclass('public.room_charges') is null then return; end if;
  d := pg_get_functiondef('public.stay_remove(uuid)'::regprocedure);
  if position('room_charges rc' in d) = 0 then
    n := replace(d, E'  -- what is on the stay with no money taken',
      E'  if exists (select 1 from public.room_charges rc where rc.stay_id = s.id) then\n    raise exception ''There are charges on this room bill (cafe, shop or packages). Set the stay to Cancelled instead, or move the charges first.'';\n  end if;\n  -- what is on the stay with no money taken');
    if n = d then raise notice 'stay_remove_charges: stay_remove is different, skipped'; else execute n; end if;
  end if;
end $p$;
