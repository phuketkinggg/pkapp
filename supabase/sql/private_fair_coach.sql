-- Any free coach, shared fairly (feature private_fair_coach, on unless turned off): when a customer books a private with
-- any free coach, in the app or on the website, the coach free at that time with the fewest privates that month is chosen
-- (past and future privates of that month, not cancelled; a request counts for the coach it was asked of). Coaches with their own
-- higher private rate are still only chosen when no other coach is free. Off: a free coach at random, as before.
-- The booking slots carry, for each month shown, the coaches in order (fewest privates first). Only the order, never the numbers.
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.private_book_slots(date,integer)') is null then raise notice 'no private_book_slots here, skipped'; return; end if;
  d := pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure);
  if position('''fair''' in d) > 0 then raise notice 'private_book_slots already patched'; return; end if;
  n := replace(d, $x$'any_first', private.feature('private_any_coach', true),$x$,
    $x$'any_first', private.feature('private_any_coach', true),
    'fair', case when private.feature('private_fair_coach', true) then (select jsonb_object_agg(to_char(m, 'YYYY-MM'),
        coalesce((select jsonb_agg(s.id order by (select count(*) from public.privates p where coalesce(p.coach_id, p.preferred_coach_id) = s.id
            and p.status <> 'cancelled' and p.date >= m::date and p.date < (m + interval '1 month')::date), s.name)
          from private.bookable_coaches() s where not s.privates_off), '[]'::jsonb))
      from generate_series(date_trunc('month', f::timestamp), date_trunc('month', (f + (n - 1))::timestamp), interval '1 month') m) end,$x$);
  if n = d then raise notice 'private_book_slots: older version, skipped'; return; end if;
  execute n;
  if position('''fair''' in pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure)) = 0 then raise exception 'private_book_slots patch did not apply'; end if;
end $p$;
notify pgrst, 'reload schema';
