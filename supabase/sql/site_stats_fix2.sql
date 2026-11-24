-- Website numbers, two fixes:
-- 1. Time per visit counted 30 minutes for every click that was not a time reading (LEAST ignores NULL), so it showed hours.
--    Now only the time readings count, and one visit counts at most 1 hour.
-- 2. The stay page sends "started their details", "asked on WhatsApp", "emailed the quote" and "added the course",
--    but the website dropped them. They are kept now, and Room bookings shows the details step.

do $p$
declare d text; n text;
begin
  d := pg_get_functiondef('public.site_track(jsonb)'::regprocedure);
  if position('stay_form' in d) = 0 then
    n := replace(d, '''stay_dates'',''stay_full'',''stay_room'',''stay_pay'',', '''stay_dates'',''stay_full'',''stay_room'',''stay_form'',''stay_wa'',''stay_quote'',''stay_course'',''stay_pay'',');
    if n = d then raise notice 'site_stats_fix2: site_track is different, skipped'; else execute n; end if;
  end if;
  if to_regprocedure('private.site_more(timestamp with time zone,timestamp with time zone)') is not null then
    d := pg_get_functiondef('private.site_more(timestamp with time zone,timestamp with time zone)'::regprocedure);
    if position('least(item::int, 1800)' in d) = 0 then
      n := replace(d, 'sum(least(case when ev = ''time'' and item ~ ''^[0-9]{1,5}$'' then item::int end, 1800)) secs,',
        'least(sum(case when ev = ''time'' and item ~ ''^[0-9]{1,5}$'' then least(item::int, 1800) end), 3600) secs,');
      if n = d then raise notice 'site_stats_fix2: site_more is different, skipped'; else execute n; end if;
    end if;
    -- a visit with no time reading must count 0, not the 1 hour cap (LEAST ignores NULL)
    d := pg_get_functiondef('private.site_more(timestamp with time zone,timestamp with time zone)'::regprocedure);
    if position('least(sum(case when ev = ''time''' in d) > 0 then
      n := replace(replace(d, 'least(sum(case when ev = ''time''', 'least(coalesce(sum(case when ev = ''time'''), 'then least(item::int, 1800) end), 3600) secs', 'then least(item::int, 1800) end), 0), 3600) secs');
      if n = d then raise notice 'site_stats_fix2: site_more cap is different, skipped'; else execute n; end if;
    end if;
  end if;
  d := pg_get_functiondef('public.site_stats(date,date)'::regprocedure);
  if position('stay_form' in d) = 0 then
    n := replace(d, '''room'', count(distinct sid) filter (where ev = ''stay_room''),',
      '''room'', count(distinct sid) filter (where ev = ''stay_room''),
        ''form'', count(distinct sid) filter (where ev = ''stay_form''),
        ''wa'', count(distinct sid) filter (where ev = ''stay_wa''),
        ''quote'', count(distinct sid) filter (where ev = ''stay_quote''),');
    if n = d then raise notice 'site_stats_fix2: site_stats is different, skipped'; else execute n; end if;
  end if;
end $p$;
