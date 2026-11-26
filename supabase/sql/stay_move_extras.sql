-- Packages for a stay move with the stay (feature stay_move_extras, on by default).
-- When a stay's dates change, its meal plans, deal items and booking extras move too. Before, only the
-- included group training moved, so a stay booked for one date and moved later kept its breakfasts on the old date.
-- A package that ran to the end of the stay keeps running to the new end; other dates move by as many days as the arrival moved.

create or replace function private.stay_move_extras() returns trigger language plpgsql security definer set search_path = '' as $f$
declare shift int := new.check_in - old.check_in;
begin
  if (new.check_in = old.check_in and new.check_out = old.check_out) or not private.feature('stay_move_extras', true) then return new; end if;
  update public.purchases k set
    starts_on = case when k.starts_on is null then null else k.starts_on + shift end,
    expires_on = case when k.expires_on is null then null
      when k.expires_on between old.check_out - 1 and old.check_out then new.check_out - (old.check_out - k.expires_on)
      else k.expires_on + shift end,
    duration_days = case when k.duration_days is not null and k.expires_on between old.check_out - 1 and old.check_out then greatest(1, new.check_out - new.check_in) else k.duration_days end
  where (k.for_stay = new.id or k.stay_id = new.id) and not coalesce(k.cancelled, false)
    and k.package_name <> 'Stay: group Muay Thai included'
    and k.starts_on is not distinct from old.check_in;
  return new;
end $f$;
revoke all on function private.stay_move_extras() from public, anon, authenticated;
drop trigger if exists stays_move_extras on public.stays;
create trigger stays_move_extras after update of check_in, check_out on public.stays
  for each row execute function private.stay_move_extras();
