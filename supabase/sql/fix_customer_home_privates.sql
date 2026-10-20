-- class_coaches.sql also rewrote the coach name on private lessons (alias k does not exist there),
-- so members with a private got "missing FROM-clause entry for table k". Put the private's coach back.
do $$
declare f text; src text; n text;
begin
  foreach f in array array['public.customer_home()','public.customer_home_as(uuid)'] loop
    src := pg_get_functiondef(f::regprocedure);
    n := replace(src, '''coach'', (select string_agg(s2.name, '', '' order by s2.name) from public.staff s2 where s2.id = any(k.coach_ids) and s2.active and not private.on_holiday(s2.id, private.bkk_today())), ''preferred''', '''coach'', s.name, ''preferred''');
    if n = src then raise exception '% not changed', f; end if;
    execute n;
  end loop;
end $$;
