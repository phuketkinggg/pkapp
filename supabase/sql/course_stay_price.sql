-- Resort guest price for a course (feature course_stay_price, on unless switched off): a course can have a lower price for anyone
-- with a stay booked or staying now. Buying on the website (or from the app, which opens the website) checks the email: a guest
-- with a stay gets the guest price. Set it on the course (Courses, Edit, Price for resort guests).

alter table public.courses add column if not exists stay_price_thb integer;

create or replace function private.course_price_for(p_course uuid, p_email text) returns integer language sql stable security definer set search_path to '' as $f$
  select case when c.stay_price_thb is not null and c.stay_price_thb >= 20 and private.feature('course_stay_price', true)
      and exists (select 1 from public.stays s join public.customers cu on cu.id = s.customer_id
                  where lower(cu.email) = lower(btrim(coalesce(p_email, ''))) and coalesce(p_email, '') <> ''
                    and s.status in ('booked', 'in') and s.check_out >= private.bkk_today())
    then least(c.stay_price_thb, c.price_thb) else c.price_thb end
  from public.courses c where c.id = p_course
$f$;

do $p$
declare d text; n text;
begin
  -- the website order uses the guest price
  if to_regprocedure('public.web_pkg_order(jsonb)') is not null then
    d := pg_get_functiondef('public.web_pkg_order(jsonb)'::regprocedure);
    if position('course_price_for' in d) = 0 then
      n := replace(replace(d, $x$values (c.id, 'Course: ' || c.title, c.price_thb,$x$, $x$values (c.id, 'Course: ' || c.title, private.course_price_for(c.id, em),$x$),
        $x$'amount', c.price_thb,$x$, $x$'amount', private.course_price_for(c.id, em),$x$);
      if n = d then raise notice 'web_pkg_order: older version, skipped'; else execute n;
        if position('course_price_for' in pg_get_functiondef('public.web_pkg_order(jsonb)'::regprocedure)) = 0 then raise exception 'web_pkg_order patch did not apply'; end if; end if;
    end if;
  end if;
  -- the course form saves it
  if to_regprocedure('public.course_save(jsonb)') is not null then
    d := pg_get_functiondef('public.course_save(jsonb)'::regprocedure);
    if position('stay_price' in d) = 0 then
      n := replace(d, E'  return cid;\nexception when unique_violation', E'  if p ? ''stay_price'' then update public.courses set stay_price_thb = nullif(p->>''stay_price'','''')::numeric::int where id = cid; end if;\n  return cid;\nexception when unique_violation');
      if n = d then raise notice 'course_save: older version, skipped'; else execute n;
        if position('stay_price' in pg_get_functiondef('public.course_save(jsonb)'::regprocedure)) = 0 then raise exception 'course_save patch did not apply'; end if; end if;
    end if;
  end if;
  -- the course tells the form (and the member) the guest price
  if to_regprocedure('public.course_view(uuid)') is not null then
    d := pg_get_functiondef('public.course_view(uuid)'::regprocedure);
    if position('stay_price' in d) = 0 then
      n := replace(d, $x$'price', c.price_thb,$x$, $x$'price', c.price_thb, 'stay_price', c.stay_price_thb,$x$);
      if n = d then raise notice 'course_view: older version, skipped'; else execute n; end if;
    end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
