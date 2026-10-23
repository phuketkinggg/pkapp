-- A staff member can also be a coach: the owner, an admin or the front desk who also teaches privates or classes.
-- Their main role (and their screens) stay the same; they show up wherever coaches are picked: privates, coach hours,
-- online booking, class coaches. The coach app itself stays for coach logins.
alter table public.staff add column if not exists also_coach boolean not null default false;
grant select (also_coach) on public.staff to authenticated;

do $$ declare f text; d text; n text;
begin
  foreach f in array array['private.bookable_coaches()','private.private_clash(uuid,date,time,integer,uuid)','private.session_coaches(date,time)',
    'public.customer_home()','public.customer_home_as(uuid)','public.private_slots(date,integer,integer,uuid,uuid)','private.hours_who(uuid)',
    'public.private_decline(uuid,text,jsonb)'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(f::regprocedure);
    if position('also_coach' in d) > 0 then continue; end if;
    n := regexp_replace(d, '\m(s|st)\.role = ''coach''', '(\1.role = ''coach'' or \1.also_coach)', 'g');
    n := replace(n, 'and active and role=''coach''', 'and active and (role=''coach'' or also_coach)');
    if n = d then raise exception '% was not changed', f; end if;
    execute n;
  end loop;
end $$;
