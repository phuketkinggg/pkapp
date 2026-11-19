-- Room 360 photos on the booking page (feature room_360): each room price group can have 360 photos (the room, the bathroom, the view).
-- Guests tap "Look inside in 360" on the room. Set in the app: Settings, Website, Room 360 photos.
-- Stored in app_settings key room_360: {"<group id>": [{url, caption, vaov, yaw}]}

create or replace function public.room_360() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when private.feature('room_360', true)
    then coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'room_360'), '{}'::jsonb) else '{}'::jsonb end
$f$;

create or replace function public.room_360_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare g text; l jsonb; s jsonb; ok_url text := '^(https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/|img/)[^"<>\s]+$';
begin
  if coalesce(private.staff_role(), '') <> 'manager' or not private.can('settings') then raise exception 'Only a manager can change the website.'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'The 360 photos could not be saved.'; end if;
  for g, l in select * from jsonb_each(p) loop
    if jsonb_typeof(l) <> 'array' or jsonb_array_length(l) > 12 then raise exception 'Keep each room to 12 360 photos or fewer.'; end if;
    for s in select * from jsonb_array_elements(l) loop
      if coalesce(s->>'url', '') !~ ok_url or length(coalesce(s->>'caption', '')) > 40 then raise exception 'One of the 360 photos could not be saved.'; end if;
      if s ? 'vaov' and s->>'vaov' is not null and (s->>'vaov')::numeric not between 30 and 180 then raise exception 'One of the 360 photos could not be saved.'; end if;
    end loop;
  end loop;
  insert into public.app_settings (key, value, updated_at) values ('room_360', p::text, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.room_360();
end $f$;

revoke all on function public.room_360() from public;
revoke all on function public.room_360_save(jsonb) from public, anon;
grant execute on function public.room_360() to anon, authenticated;
grant execute on function public.room_360_save(jsonb) to authenticated;

notify pgrst, 'reload schema';
