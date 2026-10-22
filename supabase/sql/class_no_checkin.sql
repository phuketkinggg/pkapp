-- Some classes need no check in (open sessions, kids taster, free runs): they show on the timetable but never in any check in list,
-- and a check in for them is refused wherever it comes from (desk, kiosk, member app).
alter table public.classes add column if not exists no_checkin boolean not null default false;

create or replace function private.guard_no_checkin() returns trigger language plpgsql security definer set search_path to '' as $f$
begin
  if new.class_id is not null and exists (select 1 from public.classes k where k.id = new.class_id and k.no_checkin) then
    raise exception 'No check in is needed for that class.'; end if;
  return new;
end $f$;
drop trigger if exists checkins_no_checkin on public.checkins;
create trigger checkins_no_checkin before insert on public.checkins for each row execute function private.guard_no_checkin();

-- the member app needs to know which classes need no check in
do $$ declare f text; d text; begin
  foreach f in array array['public.customer_home()','public.customer_home_as(uuid)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('no_checkin' in d) = 0 then
      d := replace(d, $a$'title', k.title,
                                          'discipline', k.discipline,$a$, $b$'title', k.title, 'no_checkin', k.no_checkin,
                                          'discipline', k.discipline,$b$);
      if position('no_checkin' in d) = 0 then raise exception '% patch did not apply', f; end if;
      execute d;
    end if;
  end loop;
end $$;
