-- Gym tour: an area can have several 360 photos (zones[].panos: [{url, caption, yaw, vaov}]), shown with a button for each.
-- Replaces site_tour_save from site_tour.sql with the extra checks. Feature site_tour.
create or replace function public.site_tour_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare z jsonb; ph jsonb; ok_url text := '^(https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/|img/|https://[a-z0-9.-]+/)[^"<>\s]{1,400}$';
begin
  if coalesce(private.staff_role(), '') <> 'manager' or not private.can('settings') then raise exception 'Only a manager can change the website.'; end if;
  if jsonb_typeof(p) <> 'object' or jsonb_typeof(coalesce(p->'zones', '[]'::jsonb)) <> 'array' then raise exception 'The tour could not be saved.'; end if;
  if jsonb_array_length(coalesce(p->'zones', '[]'::jsonb)) > 20 then raise exception 'Keep the tour to 20 areas or fewer.'; end if;
  if coalesce(p->>'image', '') <> '' and (p->>'image') !~ ok_url then raise exception 'The aerial photo link is not right.'; end if;
  for z in select * from jsonb_array_elements(coalesce(p->'zones', '[]'::jsonb)) loop
    if jsonb_typeof(z) <> 'object' or btrim(coalesce(z->>'name', '')) = '' or length(z->>'name') > 40 or length(coalesce(z->>'text', '')) > 600 then raise exception 'Each area needs a short name.'; end if;
    if coalesce((z->>'x')::numeric, -1) not between 0 and 100 or coalesce((z->>'y')::numeric, -1) not between 0 and 100
       or coalesce((z->>'w')::numeric, 0) not between 1 and 100 or coalesce((z->>'h')::numeric, 0) not between 1 and 100 then raise exception 'Mark where % is on the photo.', z->>'name'; end if;
    if jsonb_array_length(coalesce(z->'photos', '[]'::jsonb)) > 30 then raise exception 'Keep each area to 30 photos or fewer.'; end if;
    for ph in select * from jsonb_array_elements(coalesce(z->'photos', '[]'::jsonb)) loop
      if coalesce(ph->>'url', '') !~ ok_url or length(coalesce(ph->>'caption', '')) > 140 then raise exception 'One of the photos in % could not be saved.', z->>'name'; end if;
    end loop;
    if coalesce(z->>'pano', '') <> '' and (z->>'pano') !~ '^(https://|img/)' then raise exception 'The 360 link for % must start with https://', z->>'name'; end if;
    -- several 360 photos per area (panos), each with a short name and where it first looks (yaw) and how much of the photo is kept (vaov)
    if jsonb_typeof(coalesce(z->'panos', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(z->'panos', '[]'::jsonb)) > 8 then raise exception 'Keep each area to 8 360 photos or fewer.'; end if;
    for ph in select * from jsonb_array_elements(coalesce(z->'panos', '[]'::jsonb)) loop
      if coalesce(ph->>'url', '') !~ ok_url or length(coalesce(ph->>'caption', '')) > 60
         or coalesce(ph->>'yaw', '0') !~ '^-?[0-9]{1,3}(\.[0-9]+)?$' or coalesce(ph->>'vaov', '180') !~ '^[0-9]{1,3}(\.[0-9]+)?$' then raise exception 'One of the 360 photos in % could not be saved.', z->>'name'; end if;
    end loop;
  end loop;
  insert into public.app_settings (key, value, updated_at) values ('site_tour', p::text, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.site_tour();
end $f$;
revoke all on function public.site_tour_save(jsonb) from public, anon;
grant execute on function public.site_tour_save(jsonb) to authenticated;
notify pgrst, 'reload schema';
