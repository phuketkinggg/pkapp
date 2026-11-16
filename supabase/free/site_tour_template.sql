delete from mf.template where name like 'site_tour:%';
insert into mf.template (ord, phase, kind, name, sql) values (403641, 4, 'patch', 'site_tour:403641', $TPL$create or replace function __P__.site_tour() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when __Q__.feature('site_tour', true)
    then coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'site_tour'), '{}'::jsonb) else '{}'::jsonb end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403642, 4, 'patch', 'site_tour:403642', $TPL$create or replace function __P__.site_tour_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare z jsonb; ph jsonb; ok_url text := '^(https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/|img/|https://[a-z0-9.-]+/)[^"<>\s]{1,400}$';
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' or not __Q__.can('settings') then raise exception 'Only a manager can change the website.'; end if;
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
  insert into __P__.app_settings (key, value, updated_at) values ('site_tour', p::text, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return __P__.site_tour();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197641, 11, 'patch', 'site_tour:1197641', $TPL$revoke all on function __P__.site_tour() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197642, 11, 'patch', 'site_tour:1197642', $TPL$revoke all on function __P__.site_tour_save(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197643, 11, 'patch', 'site_tour:1197643', $TPL$grant execute on function __P__.site_tour() to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197644, 11, 'patch', 'site_tour:1197644', $TPL$grant execute on function __P__.site_tour_save(jsonb) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'site_tour:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
