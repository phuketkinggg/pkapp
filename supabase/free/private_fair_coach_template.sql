delete from mf.template where name like 'private_fair_coach:%';
insert into mf.template (ord, phase, kind, name, sql) values (1000601, 10, 'patch', 'private_fair_coach:1000601', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.private_book_slots(date,integer)') is null then raise notice 'no private_book_slots here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.private_book_slots(date,integer)'::regprocedure);
  if position('''fair''' in d) > 0 then raise notice 'private_book_slots already patched'; return; end if;
  n := replace(d, $x$'any_first', __Q__.feature('private_any_coach', true),$x$,
    $x$'any_first', __Q__.feature('private_any_coach', true),
    'fair', case when __Q__.feature('private_fair_coach', true) then (select jsonb_object_agg(to_char(m, 'YYYY-MM'),
        coalesce((select jsonb_agg(s.id order by (select count(*) from __P__.privates p where coalesce(p.coach_id, p.preferred_coach_id) = s.id
            and p.status <> 'cancelled' and p.date >= m::date and p.date < (m + interval '1 month')::date), s.name)
          from __Q__.bookable_coaches() s where not s.privates_off), '[]'::jsonb))
      from generate_series(date_trunc('month', f::timestamp), date_trunc('month', (f + (n - 1))::timestamp), interval '1 month') m) end,$x$);
  if n = d then raise notice 'private_book_slots: older version, skipped'; return; end if;
  execute n;
  if position('''fair''' in pg_get_functiondef('__P__.private_book_slots(date,integer)'::regprocedure)) = 0 then raise exception 'private_book_slots patch did not apply'; end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'private_fair_coach:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
