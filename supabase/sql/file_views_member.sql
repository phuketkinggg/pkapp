-- Members see who opened their file (feature file_views_member, on unless switched off): the member file (my_file) lists the
-- last 30 times a staff member opened it, with the name and when. Patched, checking it applied; skips where there is no member file.
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.my_file()') is null then raise notice 'no member file here, skipped'; return; end if;
  d := pg_get_functiondef('public.my_file()'::regprocedure);
  if position('member_file_views' in d) > 0 then raise notice 'my_file already patched'; return; end if;
  n := replace(d, $x$'coaches', coalesce((select jsonb_agg(s.name order by s.name) from public.coach_clients cc join public.staff s on s.id = cc.staff_id where cc.customer_id = cid), '[]'::jsonb));$x$,
    $x$'coaches', coalesce((select jsonb_agg(s.name order by s.name) from public.coach_clients cc join public.staff s on s.id = cc.staff_id where cc.customer_id = cid), '[]'::jsonb),
    'views', case when private.feature('file_views_member', true) then coalesce((select jsonb_agg(jsonb_build_object('at', v.at, 'by', coalesce(s.name, 'A former team member')) order by v.at desc)
      from (select * from public.member_file_views where customer_id = cid order by at desc limit 30) v left join public.staff s on s.id = v.staff_id), '[]'::jsonb) end);$x$);
  if n = d then raise notice 'my_file: older version, skipped'; return; end if;
  execute n;
  if position('member_file_views' in pg_get_functiondef('public.my_file()'::regprocedure)) = 0 then raise exception 'my_file patch did not apply'; end if;
end $p$;
notify pgrst, 'reload schema';
