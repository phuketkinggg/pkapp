-- Privates block the coach: each private holds the coach for its length (1 hour standard, longer with transport).
-- No two privates for one coach can overlap, and none on an approved holiday. Free times are shown when booking.

alter table public.privates add column if not exists minutes int not null default 60;
do $$ begin
  alter table public.privates add constraint privates_minutes_chk check (minutes between 15 and 600);
exception when duplicate_object then null; end $$;

insert into public.app_settings (key, value)
select 'private_hours', '{"from":"06:00","to":"21:00","step":30}'
where not exists (select 1 from public.app_settings where key = 'private_hours');

create or replace function private.private_hours() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select value::jsonb from public.app_settings where key = 'private_hours'), '{"from":"06:00","to":"21:00","step":30}'::jsonb) $$;

-- the busy blocks of one coach on one day (privates and holidays), excluding one private
create or replace function private.coach_busy(p_coach uuid, p_date date, p_except uuid default null)
returns table (b_from time, b_to time, what text) language sql stable security definer set search_path to '' as $$
  select x.start_time, least(x.start_time + make_interval(mins => x.minutes), time '23:59:59'), 'private'
    from public.privates x
   where x.coach_id = p_coach and x.date = p_date and x.status in ('confirmed','done') and (p_except is null or x.id <> p_except)
  union all
  select time '00:00', time '23:59:59', 'holiday'
    from public.holidays hd where hd.staff_id = p_coach and hd.status = 'approved' and hd.from_date <= p_date and p_date <= hd.to_date
$$;

-- free start times for one coach on one day for a private of p_minutes
create or replace function private.coach_free_times(p_coach uuid, p_date date, p_minutes int default 60, p_except uuid default null)
returns text[] language plpgsql stable security definer set search_path to '' as $$
declare hrs jsonb := private.private_hours(); t time := (hrs->>'from')::time; e time := (hrs->>'to')::time; st int := greatest(15, coalesce((hrs->>'step')::int, 30));
  now_t time := (now() at time zone 'Asia/Bangkok')::time; out text[] := '{}'; m int := greatest(15, coalesce(p_minutes, 60));
begin
  while t + make_interval(mins => m) <= e and t >= (hrs->>'from')::time loop
    if not (p_date = private.bkk_today() and t <= now_t)
       and not exists (select 1 from private.coach_busy(p_coach, p_date, p_except) b where t < b.b_to and t + make_interval(mins => m) > b.b_from) then
      out := out || to_char(t, 'HH24:MI');
    end if;
    exit when t + make_interval(mins => st) <= t;  -- wrapped past midnight
    t := t + make_interval(mins => st);
  end loop;
  return out;
end $$;

-- null when the coach is free, otherwise a message saying why and when they are free
create or replace function private.private_clash(p_coach uuid, p_date date, p_time time, p_minutes int, p_except uuid default null)
returns text language plpgsql stable security definer set search_path to '' as $$
declare n text; b record; free text[]; others text;
begin
  if p_coach is null or p_date is null or p_time is null then return null; end if;
  select name into n from public.staff where id = p_coach;
  select * into b from private.coach_busy(p_coach, p_date, p_except) x
   where p_time < x.b_to and p_time + make_interval(mins => coalesce(p_minutes,60)) > x.b_from order by x.b_from limit 1;
  if not found then return null; end if;
  select coalesce(array_agg(f order by f), '{}') into free from (
    select f from unnest(private.coach_free_times(p_coach, p_date, p_minutes, p_except)) f
    order by abs(extract(epoch from (f::time - p_time))) limit 6) z;
  select string_agg(s.name, ', ' order by s.name) into others from public.staff s
   where s.role = 'coach' and s.active and s.id <> p_coach
     and not exists (select 1 from private.coach_busy(s.id, p_date, null) y where p_time < y.b_to and p_time + make_interval(mins => coalesce(p_minutes,60)) > y.b_from);
  return case when b.what = 'holiday' then coalesce(n,'The coach') || ' is on holiday that day.'
    else coalesce(n,'The coach') || ' is busy then, with a private from ' || to_char(b.b_from,'HH24:MI') || ' to ' || to_char(b.b_to,'HH24:MI') || '.' end
    || case when cardinality(free) > 0 then ' Nearest free times that day: ' || array_to_string(free, ', ') || '.' else ' No free time that day.' end
    || case when others is not null then ' Free at ' || to_char(p_time,'HH24:MI') || ': ' || others || '.' else '' end;
end $$;

create or replace function private.guard_private_clash() returns trigger language plpgsql security definer set search_path to '' as $$
declare msg text;
begin
  if new.status not in ('confirmed','done') or new.coach_id is null then return new; end if;
  if tg_op = 'UPDATE' and old.coach_id is not distinct from new.coach_id and old.date is not distinct from new.date and old.start_time is not distinct from new.start_time
     and old.minutes is not distinct from new.minutes and old.status in ('confirmed','done') then return new; end if;
  if new.date < private.bkk_today() - 1 then return new; end if;  -- entering old history is not blocked
  msg := private.private_clash(new.coach_id, new.date, new.start_time, new.minutes, new.id);
  if msg is not null then raise exception '%', msg; end if;
  return new;
end $$;
drop trigger if exists privates_no_clash on public.privates;
create trigger privates_no_clash before insert or update on public.privates for each row execute function private.guard_private_clash();

-- free times for the booking screens: one or more days, every active coach (or one)
create or replace function public.private_slots(p_from date, p_days int default 1, p_minutes int default 60, p_coach uuid default null, p_except uuid default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare staff_view boolean := private.any_staff();
begin
  if not staff_view and private.customer_id() is null then raise exception 'Sign in first.'; end if;
  if p_days < 1 or p_days > 14 then p_days := least(14, greatest(1, p_days)); end if;
  return jsonb_build_object('hours', private.private_hours(), 'days',
    (select jsonb_agg(jsonb_build_object('date', d::date, 'coaches',
       (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name,
          'free', to_jsonb(private.coach_free_times(s.id, d::date, p_minutes, p_except)),
          'busy', case when staff_view then (select coalesce(jsonb_agg(jsonb_build_object('from', to_char(b.b_from,'HH24:MI'), 'to', to_char(b.b_to,'HH24:MI'), 'what', b.what) order by b.b_from), '[]'::jsonb)
                    from private.coach_busy(s.id, d::date, p_except) b) else '[]'::jsonb end) order by s.name), '[]'::jsonb)
        from public.staff s where s.role = 'coach' and s.active and (p_coach is null or s.id = p_coach))) order by d)
     from generate_series(p_from, p_from + (p_days - 1), interval '1 day') d));
end $$;
revoke all on function public.private_slots(date,int,int,uuid,uuid) from public, anon;
grant execute on function public.private_slots(date,int,int,uuid,uuid) to authenticated;

-- customers: the coach they ask for must be free, or someone must be free if they have no preference
do $$ declare d text := pg_get_functiondef('public.customer_request_private(uuid,date,time,text)'::regprocedure); begin
  if position('private_clash' in d) = 0 then
    d := replace(d, '  if (select count(*) from public.privates p where p.customer_id = c.id and p.status = ''requested'') >= 5 then',
      '  if p_coach is not null and private.private_clash(p_coach, p_date, p_time, 60, null) is not null then raise exception ''%'', private.private_clash(p_coach, p_date, p_time, 60, null); end if;
  if p_coach is null and not exists (select 1 from public.staff s where s.role = ''coach'' and s.active and private.private_clash(s.id, p_date, p_time, 60, null) is null) then
    raise exception ''No coach is free at % on %. Try another time.'', to_char(p_time,''HH24:MI''), to_char(p_date,''DD Mon''); end if;
  if (select count(*) from public.privates p where p.customer_id = c.id and p.status = ''requested'') >= 5 then');
    if position('private_clash' in d) = 0 then raise exception 'customer_request_private patch did not apply'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.coach_book_private(uuid,time,text,text)'::regprocedure);
  if position('private_clash' in d) = 0 then
    d := replace(d, 'if exists (select 1 from public.privates x where x.coach_id = me and x.date = t and x.start_time = p_time and x.status <> ''cancelled'') then
    raise exception ''You already have a private at that time.''; end if;',
      'if private.private_clash(me, t, p_time, 60, null) is not null then raise exception ''%'', private.private_clash(me, t, p_time, 60, null); end if;');
    if position('private_clash' in d) = 0 then raise exception 'coach_book_private patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- coaches see when each private ends
do $$ declare d text := pg_get_functiondef('public.coach_home()'::regprocedure); begin
  if position('''until''' in d) = 0 then
    d := replace(d, '''time'', to_char(p.start_time, ''HH24:MI''), ''status'', p.status, ''arrived_at''',
      '''time'', to_char(p.start_time, ''HH24:MI''), ''until'', to_char(p.start_time + make_interval(mins => p.minutes), ''HH24:MI''), ''minutes'', p.minutes, ''status'', p.status, ''arrived_at''');
    if position('''until''' in d) = 0 then raise exception 'coach_home patch did not apply'; end if;
    execute d;
  end if;
end $$;
