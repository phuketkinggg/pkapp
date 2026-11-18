-- Printable class schedule (feature schedule_print): schedule.html shows the week's group classes as a page people can view,
-- print or save as a PDF. For everyone, or one coach (their own schedule), or one kind of class. Opened from Timetable, Print or share.
create or replace function public.schedule_public(p_coach uuid default null, p_discipline text default null) returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when not private.feature('schedule_print', true) then jsonb_build_object('off', true) else jsonb_build_object(
    'business', private.biz_main(),
    'accent', coalesce((select case when value ~ '^\s*\{' then value::jsonb->>'accent' end from public.app_settings where key = 'app_theme'), '#B88A44'),
    'coach', (select coalesce(nullif(btrim(s.web_name), ''), s.name) from public.staff s where s.id = p_coach),
    'classes', coalesce((select jsonb_agg(jsonb_build_object(
        'day', c.day, 'start', to_char(c.start_time, 'HH24:MI'), 'end', to_char(c.end_time, 'HH24:MI'), 'title', c.title, 'discipline', c.discipline,
        'coaches', (select jsonb_agg(coalesce(nullif(btrim(s.web_name), ''), s.name) order by s.name) from public.staff s
                    where s.active and s.id = any(coalesce(nullif(c.coach_ids, '{}'), array[c.coach_id]))))
      order by c.day, c.start_time)
      from public.classes c
      where (p_coach is null or p_coach = any(coalesce(nullif(c.coach_ids, '{}'), array[c.coach_id])))
        and (p_discipline is null or c.discipline = p_discipline)), '[]'::jsonb)) end
$f$;
revoke all on function public.schedule_public(uuid, text) from public;
grant execute on function public.schedule_public(uuid, text) to anon, authenticated;
notify pgrst, 'reload schema';
