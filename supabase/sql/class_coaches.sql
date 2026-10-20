-- Classes can have several coaches. The coaches on a class clock in for it; coaches not on it do not.
-- A coach on approved holiday is left out of their classes for those days automatically.
alter table public.classes add column if not exists coach_ids uuid[] not null default '{}';
update public.classes set coach_ids = array[coach_id] where coach_id is not null and coach_ids = '{}';

-- the coaches who actually run a class on a given day (holidays taken out)
create or replace function private.class_coaches(p_class uuid, d date) returns uuid[] language sql stable security definer set search_path='' as $f$
  select coalesce(array_agg(s.id order by s.name), '{}') from public.classes k join public.staff s on s.id = any(k.coach_ids) and s.active
  where k.id = p_class and not private.on_holiday(s.id, d)
$f$;

-- the old "every coach clocks in to every session" list only applies while no class has coaches set
create or replace function private.sessions_on() returns boolean language sql stable security definer set search_path='' as $f$
  select not exists (select 1 from public.classes where cardinality(coach_ids) > 0)
$f$;

do $$
declare d text;
begin
  -- coach's own app
  d := pg_get_functiondef('public.coach_home()'::regprocedure);
  d := replace(d, 'from public.classes k where k.coach_id = v_coach)', 'from public.classes k where v_coach = any(k.coach_ids))');
  execute d;

  -- clocking in to a class: any coach on that class
  d := pg_get_functiondef('public.staff_clock_punch(text,text,uuid,text)'::regprocedure);
  d := replace(d, 'select * into k from public.classes where id = p_ref and coach_id = me and day', 'select * into k from public.classes where id = p_ref and me = any(coach_ids) and day');
  execute d;

  -- today's list on the clock page: my classes, not on holiday; old sessions only if classes have no coaches yet
  d := pg_get_functiondef('public.staff_clock_today()'::regprocedure);
  d := replace(d, 'from public.classes k where k.coach_id = me and k.day', 'from public.classes k where me = any(k.coach_ids) and not private.on_holiday(me, t) and k.day');
  d := replace(d, '''sessions'', case when r = ''coach'' and not private.on_holiday(me, t) then', '''sessions'', case when r = ''coach'' and private.sessions_on() and not private.on_holiday(me, t) then');
  execute d;

  -- staff hours: missed classes for every coach on the class, holidays left out
  d := pg_get_functiondef('public.staff_hours(date,date)'::regprocedure);
  d := replace(d, '''missed_classes'', (select coalesce(jsonb_agg(jsonb_build_object(''staff_id'', k.coach_id,', '''missed_classes'', (select coalesce(jsonb_agg(jsonb_build_object(''staff_id'', s.id,');
  d := replace(d, 'join public.classes k on k.day = extract(isodow from d)::int - 1 and k.coach_id is not null
      join public.staff s on s.id = k.coach_id and s.active', 'join public.classes k on k.day = extract(isodow from d)::int - 1
      join public.staff s on s.id = any(k.coach_ids) and s.active');
  d := replace(d, 'and not exists (select 1 from public.staff_clock c where c.kind = ''class'' and c.ref_id = k.id and c.day = d::date and not c.voided)));',
                  'and not private.on_holiday(s.id, d::date)
        and not exists (select 1 from public.staff_clock c where c.kind = ''class'' and c.ref_id = k.id and c.staff_id = s.id and c.day = d::date and not c.voided)));');
  d := replace(d, 'where (g.d < private.bkk_today() or x.s < (now() at time zone ''Asia/Bangkok'')::time)
        and not private.on_holiday(st.id, g.d)', 'where (g.d < private.bkk_today() or x.s < (now() at time zone ''Asia/Bangkok'')::time)
        and private.sessions_on()
        and not private.on_holiday(st.id, g.d)');
  execute d;

  -- member app: the coaches of each class
  foreach d in array array['public.customer_home()','public.customer_home_as(uuid)'] loop
    declare f text := d; src text;
    begin
      src := pg_get_functiondef(f::regprocedure);
      src := replace(src, '''coach'', s.name, ''off_from''', '''coach'', (select string_agg(s2.name, '', '' order by s2.name) from public.staff s2 where s2.id = any(k.coach_ids) and s2.active and not private.on_holiday(s2.id, private.bkk_today())), ''off_from''');  -- classes only, not privates
      execute src;
    end;
  end loop;
end $$;
