-- Courses in the member app, separate from coaching: an action group linked to a course (Courses, Groups in this course)
-- now says which course it belongs to, and lists the steps still to come (name, type and day only, never their content),
-- so the course page can show every step in order: to do, coming up, done.
do $$ declare s text;
begin
  s := pg_get_functiondef('private.group_data(uuid,boolean)'::regprocedure);
  if s like '%course_id%' then return; end if;
  s := replace(s, $a$'group_id',g.id,$a$,
    $a$'group_id',g.id,'course_id',(select c.id from public.courses c where g.id = any(c.group_ids) and c.status = 'published' order by c.created_at limit 1),
      'later',coalesce((select jsonb_agg(jsonb_build_object('id',it->>'id','title',it->>'title','kind',it->>'kind','on',private.step_on(it,m.start_on)) order by private.step_on(it,m.start_on), o)
         from jsonb_array_elements(g.items) with ordinality as y(it,o) where private.step_on(it,m.start_on) > private.bkk_today() and it->>'kind' <> 'email'),'[]'::jsonb),$a$);
  if s not like '%course_id%' then raise notice 'group_data is a different version here: skipped.'; return; end if;
  execute s;
end $$;
