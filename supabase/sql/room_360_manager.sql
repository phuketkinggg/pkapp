-- Room 360 photos: managers see and edit them in the app before they are on the website (feature room_360 off).
-- Guests (the booking page) still get nothing until the feature is on.
create or replace function public.room_360() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when private.feature('room_360', true) or coalesce(private.staff_role(), '') = 'manager'
    then coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'room_360'), '{}'::jsonb) else '{}'::jsonb end
$f$;
revoke all on function public.room_360() from public;
grant execute on function public.room_360() to anon, authenticated;
notify pgrst, 'reload schema';
