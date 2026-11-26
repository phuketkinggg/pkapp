-- Meal plans for a stay run to the check-out day (feature meal_checkout, on by default).
-- Check-in is in the afternoon, so the day they arrive they get dinner, and the day they leave breakfast and lunch:
-- 3 meals a night in all. Before, a plan ended the day before check-out, so the kitchen could not serve
-- breakfast and lunch on the last day. The kitchen list also says which meals are due on the first and last day.

create or replace function private.meal_to_checkout() returns trigger language plpgsql security definer set search_path = '' as $f$
declare co date;
begin
  if new.covers is distinct from array['Cafe meal'] or coalesce(new.stay_id, new.for_stay) is null or new.expires_on is null then return new; end if;
  if not private.feature('meal_checkout', true) then return new; end if;
  select s.check_out into co from public.stays s where s.id = coalesce(new.stay_id, new.for_stay);
  if co is not null and new.expires_on = co - 1 then new.expires_on := co; end if;
  return new;
end $f$;
revoke all on function private.meal_to_checkout() from public, anon, authenticated;
drop trigger if exists purchases_meal_checkout on public.purchases;
create trigger purchases_meal_checkout before insert or update of expires_on, stay_id, for_stay on public.purchases
  for each row execute function private.meal_to_checkout();

-- plans running now or later: to the check-out day
update public.purchases k set expires_on = s.check_out
from public.stays s
where s.id = coalesce(k.stay_id, k.for_stay) and k.covers = array['Cafe meal'] and not coalesce(k.cancelled, false)
  and k.expires_on = s.check_out - 1 and s.check_out >= private.bkk_today() and private.feature('meal_checkout', true);

-- the kitchen list: when the plan starts and the room's check-out, for "Arrived today: dinner" and "Leaving today: breakfast and lunch"
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.meal_plans_today()') is null then return; end if;
  d := pg_get_functiondef('public.meal_plans_today()'::regprocedure);
  if position('''from'', k.starts_on' in d) = 0 then
    n := replace(d, '''until'', k.expires_on,', '''until'', k.expires_on, ''from'', k.starts_on,
      ''leaves'', (select s.check_out from public.stays s where s.id = coalesce(k.stay_id, k.for_stay)),');
    if n = d then raise notice 'meal_checkout: meal_plans_today is different, skipped'; else execute n; end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
