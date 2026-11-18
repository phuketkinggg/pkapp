delete from mf.template where name like 'schedule_public:%';
insert into mf.template (ord, phase, kind, name, sql) values (403711, 4, 'patch', 'schedule_public:403711', $TPL$create or replace function __P__.schedule_public(p_coach uuid default null, p_discipline text default null) returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when not __Q__.feature('schedule_print', true) then jsonb_build_object('off', true) else jsonb_build_object(
    'business', __Q__.biz_main(),
    'accent', coalesce((select case when value ~ '^\s*\{' then value::jsonb->>'accent' end from __P__.app_settings where key = 'app_theme'), '#B88A44'),
    'coach', (select coalesce(nullif(btrim(s.web_name), ''), s.name) from __P__.staff s where s.id = p_coach),
    'classes', coalesce((select jsonb_agg(jsonb_build_object(
        'day', c.day, 'start', to_char(c.start_time, 'HH24:MI'), 'end', to_char(c.end_time, 'HH24:MI'), 'title', c.title, 'discipline', c.discipline,
        'coaches', (select jsonb_agg(coalesce(nullif(btrim(s.web_name), ''), s.name) order by s.name) from __P__.staff s
                    where s.active and s.id = any(coalesce(nullif(c.coach_ids, '{}'), array[c.coach_id]))))
      order by c.day, c.start_time)
      from __P__.classes c
      where (p_coach is null or p_coach = any(coalesce(nullif(c.coach_ids, '{}'), array[c.coach_id])))
        and (p_discipline is null or c.discipline = p_discipline)), '[]'::jsonb)) end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197711, 11, 'patch', 'schedule_public:1197711', $TPL$revoke all on function __P__.schedule_public(uuid, text) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197712, 11, 'patch', 'schedule_public:1197712', $TPL$grant execute on function __P__.schedule_public(uuid, text) to anon, authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'schedule_public:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
