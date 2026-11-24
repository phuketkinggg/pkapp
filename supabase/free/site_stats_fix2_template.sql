delete from mf.template where name like 'site_stats_fix2:%';
insert into mf.template (ord, phase, kind, name, sql) values (1003501, 10, 'patch', 'site_stats_fix2:1003501', $TPL$do $p$
declare d text; n text;
begin
  d := pg_get_functiondef('__P__.site_track(jsonb)'::regprocedure);
  if position('stay_form' in d) = 0 then
    n := replace(d, '''stay_dates'',''stay_full'',''stay_room'',''stay_pay'',', '''stay_dates'',''stay_full'',''stay_room'',''stay_form'',''stay_wa'',''stay_quote'',''stay_course'',''stay_pay'',');
    if n = d then raise notice 'site_stats_fix2: site_track is different, skipped'; else execute n; end if;
  end if;
  if to_regprocedure('__Q__.site_more(timestamp with time zone,timestamp with time zone)') is not null then
    d := pg_get_functiondef('__Q__.site_more(timestamp with time zone,timestamp with time zone)'::regprocedure);
    if position('least(item::int, 1800)' in d) = 0 then
      n := replace(d, 'sum(least(case when ev = ''time'' and item ~ ''^[0-9]{1,5}$'' then item::int end, 1800)) secs,',
        'least(sum(case when ev = ''time'' and item ~ ''^[0-9]{1,5}$'' then least(item::int, 1800) end), 3600) secs,');
      if n = d then raise notice 'site_stats_fix2: site_more is different, skipped'; else execute n; end if;
    end if;
    -- a visit with no time reading must count 0, not the 1 hour cap (LEAST ignores NULL)
    d := pg_get_functiondef('__Q__.site_more(timestamp with time zone,timestamp with time zone)'::regprocedure);
    if position('least(sum(case when ev = ''time''' in d) > 0 then
      n := replace(replace(d, 'least(sum(case when ev = ''time''', 'least(coalesce(sum(case when ev = ''time'''), 'then least(item::int, 1800) end), 3600) secs', 'then least(item::int, 1800) end), 0), 3600) secs');
      if n = d then raise notice 'site_stats_fix2: site_more cap is different, skipped'; else execute n; end if;
    end if;
  end if;
  d := pg_get_functiondef('__P__.site_stats(date,date)'::regprocedure);
  if position('stay_form' in d) = 0 then
    n := replace(d, '''room'', count(distinct sid) filter (where ev = ''stay_room''),',
      '''room'', count(distinct sid) filter (where ev = ''stay_room''),
        ''form'', count(distinct sid) filter (where ev = ''stay_form''),
        ''wa'', count(distinct sid) filter (where ev = ''stay_wa''),
        ''quote'', count(distinct sid) filter (where ev = ''stay_quote''),');
    if n = d then raise notice 'site_stats_fix2: site_stats is different, skipped'; else execute n; end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'site_stats_fix2:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
