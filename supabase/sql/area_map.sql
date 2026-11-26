-- Map of the area for guests (feature area_map, off by default).
-- The business sets a link (Settings, Rooms and stays, Map of the area), for example its own map page of the rooms,
-- gym and shops nearby. Guests with a stay see a Map of the area button in their app.

create or replace function public.area_map_url() returns text language sql stable security definer set search_path = '' as $f$
  select case when private.feature('area_map', false) then
    (select v from (select btrim(value) v from public.app_settings where key = 'area_map_url') x where v ~ '^https://[^\s<>"]+$') end
$f$;
revoke all on function public.area_map_url() from public;
grant execute on function public.area_map_url() to anon, authenticated;

notify pgrst, 'reload schema';
