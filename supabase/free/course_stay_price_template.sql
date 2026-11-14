delete from mf.template where name like 'course_stay_price:%';
insert into mf.template (ord, phase, kind, name, sql) values (303301, 3, 'patch', 'course_stay_price:303301', $TPL$alter table __P__.courses add column if not exists stay_price_thb integer;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403401, 4, 'patch', 'course_stay_price:403401', $TPL$create or replace function __Q__.course_price_for(p_course uuid, p_email text) returns integer language sql stable security definer set search_path to '' as $f$
  select case when c.stay_price_thb is not null and c.stay_price_thb >= 20 and __Q__.feature('course_stay_price', true)
      and exists (select 1 from __P__.stays s join __P__.customers cu on cu.id = s.customer_id
                  where lower(cu.email) = lower(btrim(coalesce(p_email, ''))) and coalesce(p_email, '') <> ''
                    and s.status in ('booked', 'in') and s.check_out >= __Q__.bkk_today())
    then least(c.stay_price_thb, c.price_thb) else c.price_thb end
  from __P__.courses c where c.id = p_course
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002001, 10, 'patch', 'course_stay_price:1002001', $TPL$do $p$
declare d text; n text;
begin
  -- the website order uses the guest price
  if to_regprocedure('__P__.web_pkg_order(jsonb)') is not null then
    d := pg_get_functiondef('__P__.web_pkg_order(jsonb)'::regprocedure);
    if position('course_price_for' in d) = 0 then
      n := replace(replace(d, $x$values (c.id, 'Course: ' || c.title, c.price_thb,$x$, $x$values (c.id, 'Course: ' || c.title, __Q__.course_price_for(c.id, em),$x$),
        $x$'amount', c.price_thb,$x$, $x$'amount', __Q__.course_price_for(c.id, em),$x$);
      if n = d then raise notice 'web_pkg_order: older version, skipped'; else execute n;
        if position('course_price_for' in pg_get_functiondef('__P__.web_pkg_order(jsonb)'::regprocedure)) = 0 then raise exception 'web_pkg_order patch did not apply'; end if; end if;
    end if;
  end if;
  -- the course form saves it
  if to_regprocedure('__P__.course_save(jsonb)') is not null then
    d := pg_get_functiondef('__P__.course_save(jsonb)'::regprocedure);
    if position('stay_price' in d) = 0 then
      n := replace(d, E'  return cid;\nexception when unique_violation', E'  if p ? ''stay_price'' then update __P__.courses set stay_price_thb = nullif(p->>''stay_price'','''')::numeric::int where id = cid; end if;\n  return cid;\nexception when unique_violation');
      if n = d then raise notice 'course_save: older version, skipped'; else execute n;
        if position('stay_price' in pg_get_functiondef('__P__.course_save(jsonb)'::regprocedure)) = 0 then raise exception 'course_save patch did not apply'; end if; end if;
    end if;
  end if;
  -- the course tells the form (and the member) the guest price
  if to_regprocedure('__P__.course_view(uuid)') is not null then
    d := pg_get_functiondef('__P__.course_view(uuid)'::regprocedure);
    if position('stay_price' in d) = 0 then
      n := replace(d, $x$'price', c.price_thb,$x$, $x$'price', c.price_thb, 'stay_price', c.stay_price_thb,$x$);
      if n = d then raise notice 'course_view: older version, skipped'; else execute n; end if;
    end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'course_stay_price:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
