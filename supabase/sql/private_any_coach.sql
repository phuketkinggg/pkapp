-- Book a private with any free coach (feature: private_any_coach, on unless turned off). The booking slots tell the picker
-- whether to start with "Any free coach" (the guest picks a day and time, a free coach is chosen) or with the list of coaches.
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.private_book_slots(date, integer)') is null then raise notice 'no private_book_slots here, skipped'; return; end if;
  d := pg_get_functiondef('public.private_book_slots(date, integer)'::regprocedure);
  if position('any_first' in d) > 0 then raise notice 'private_book_slots already has any_first'; return; end if;
  n := replace(d, 'return jsonb_build_object(''today'', t, ''from'', f,', 'return jsonb_build_object(''today'', t, ''from'', f, ''any_first'', private.feature(''private_any_coach'', true),');
  if n = d then raise exception 'private_book_slots patch did not apply'; end if;
  execute n;
end $p$;
notify pgrst, 'reload schema';
