-- Gym tour on the website (feature site_tour): an aerial photo of the gym with its areas marked. Tap an area to see its photos
-- (and later a 360 view). Set in the app: Settings, Website, Gym tour. Stored in app_settings key site_tour:
-- {image, title, text, zones:[{id, name, text, x, y, w, h (percent of the photo), photos:[{url, caption}], pano}]}

create or replace function public.site_tour() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when private.feature('site_tour', true)
    then coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'site_tour'), '{}'::jsonb) else '{}'::jsonb end
$f$;

create or replace function public.site_tour_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare z jsonb; ph jsonb; ok_url text := '^(https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/|img/|https://[a-z0-9.-]+/)[^"<>\s]+$';
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
    if coalesce(z->>'pano', '') <> '' and (z->>'pano') !~ '^https://' then raise exception 'The 360 link for % must start with https://', z->>'name'; end if;
  end loop;
  insert into public.app_settings (key, value, updated_at) values ('site_tour', p::text, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.site_tour();
end $f$;

revoke all on function public.site_tour() from public;
revoke all on function public.site_tour_save(jsonb) from public, anon;
grant execute on function public.site_tour() to anon, authenticated;
grant execute on function public.site_tour_save(jsonb) to authenticated;

notify pgrst, 'reload schema';
