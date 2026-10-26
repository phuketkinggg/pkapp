-- Action groups: a step can point to a lesson of an online course ("Open lesson 3 today"), so the group's days set the
-- pace and the course keeps the videos. Step fields: kind 'lesson', course_id, lesson_id.
do $$ declare s text;
begin
  s := pg_get_functiondef('public.group_save(jsonb)'::regprocedure);
  if s like '%''lesson''%' then return; end if;
  s := replace(s, $a$not in ('video','doc','note','habit','food','weight','program','email') then raise exception 'Unknown step type.'; end if;$a$,
    $a$not in ('video','doc','note','habit','food','weight','program','email','lesson') then raise exception 'Unknown step type.'; end if;
    if x->>'kind' = 'lesson' and not exists (select 1 from public.course_lessons l where l.id::text = coalesce(x->>'lesson_id','') and not l.removed) then raise exception 'Pick the lesson for "%".', coalesce(nullif(x->>'title',''),'a step'); end if;$a$);
  if s not like '%''lesson''%' then raise notice 'group_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;
