delete from mf.template where name like 'private_any_skip:%';
insert into mf.template (ord, phase, kind, name, sql) values (302201, 3, 'patch', 'private_any_skip:302201', $TPL$alter table __P__.staff add column if not exists privates_any boolean not null default true;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196201, 11, 'patch', 'private_any_skip:1196201', $TPL$grant select (privates_any), insert (privates_any), update (privates_any) on __P__.staff to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1000701, 10, 'patch', 'private_any_skip:1000701', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.private_book_slots(date,integer)') is null then raise notice 'no private_book_slots here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.private_book_slots(date,integer)'::regprocedure);
  if position('privates_any' in d) > 0 then raise notice 'private_book_slots already patched'; return; end if;
  n := replace(d, $x$'rate', (select x.private_rate_thb from __P__.staff x where x.id = s.id))$x$,
    $x$'rate', (select x.private_rate_thb from __P__.staff x where x.id = s.id), 'any', (select x.privates_any from __P__.staff x where x.id = s.id))$x$);
  n := replace(n, $x$from __Q__.bookable_coaches() s where not s.privates_off), '[]'::jsonb))$x$,
    $x$from __Q__.bookable_coaches() s where not s.privates_off and s.privates_any), '[]'::jsonb))$x$);
  if n = d or position('s.privates_any' in n) = 0 then raise notice 'private_book_slots: older version, skipped'; return; end if;
  execute n;
  if position('privates_any' in pg_get_functiondef('__P__.private_book_slots(date,integer)'::regprocedure)) = 0 then raise exception 'private_book_slots patch did not apply'; end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'private_any_skip:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
