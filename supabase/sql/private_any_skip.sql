-- A coach can be left out of "any free coach" privates (Staff, the coach, "Gets any free coach privates"): customers can still
-- pick them by name, but a private booked with any free coach never goes to them, and times only they are free are not offered then.
-- Needs private_fair_coach.sql. Patches check they applied and skip cleanly where a database is older.
alter table public.staff add column if not exists privates_any boolean not null default true;
grant select (privates_any), insert (privates_any), update (privates_any) on public.staff to authenticated;

do $p$
declare d text; n text;
begin
  if to_regprocedure('public.private_book_slots(date,integer)') is null then raise notice 'no private_book_slots here, skipped'; return; end if;
  d := pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure);
  if position('privates_any' in d) > 0 then raise notice 'private_book_slots already patched'; return; end if;
  n := replace(d, $x$'rate', (select x.private_rate_thb from public.staff x where x.id = s.id))$x$,
    $x$'rate', (select x.private_rate_thb from public.staff x where x.id = s.id), 'any', (select x.privates_any from public.staff x where x.id = s.id))$x$);
  n := replace(n, $x$from private.bookable_coaches() s where not s.privates_off), '[]'::jsonb))$x$,
    $x$from private.bookable_coaches() s where not s.privates_off and s.privates_any), '[]'::jsonb))$x$);
  if n = d or position('s.privates_any' in n) = 0 then raise notice 'private_book_slots: older version, skipped'; return; end if;
  execute n;
  if position('privates_any' in pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure)) = 0 then raise exception 'private_book_slots patch did not apply'; end if;
end $p$;
notify pgrst, 'reload schema';
