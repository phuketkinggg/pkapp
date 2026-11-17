delete from mf.template where name like 'room_360:%';
insert into mf.template (ord, phase, kind, name, sql) values (403691, 4, 'patch', 'room_360:403691', $TPL$create or replace function __P__.room_360() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when __Q__.feature('room_360', true)
    then coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'room_360'), '{}'::jsonb) else '{}'::jsonb end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403692, 4, 'patch', 'room_360:403692', $TPL$create or replace function __P__.room_360_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare g text; l jsonb; s jsonb; ok_url text := '^(https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/|img/)[^"<>\s]{1,400}$';
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' or not __Q__.can('settings') then raise exception 'Only a manager can change the website.'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'The 360 photos could not be saved.'; end if;
  for g, l in select * from jsonb_each(p) loop
    if jsonb_typeof(l) <> 'array' or jsonb_array_length(l) > 12 then raise exception 'Keep each room to 12 360 photos or fewer.'; end if;
    for s in select * from jsonb_array_elements(l) loop
      if coalesce(s->>'url', '') !~ ok_url or length(coalesce(s->>'caption', '')) > 40 then raise exception 'One of the 360 photos could not be saved.'; end if;
      if s ? 'vaov' and s->>'vaov' is not null and (s->>'vaov')::numeric not between 30 and 180 then raise exception 'One of the 360 photos could not be saved.'; end if;
    end loop;
  end loop;
  insert into __P__.app_settings (key, value, updated_at) values ('room_360', p::text, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return __P__.room_360();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197691, 11, 'patch', 'room_360:1197691', $TPL$revoke all on function __P__.room_360() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197692, 11, 'patch', 'room_360:1197692', $TPL$revoke all on function __P__.room_360_save(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197693, 11, 'patch', 'room_360:1197693', $TPL$grant execute on function __P__.room_360() to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197694, 11, 'patch', 'room_360:1197694', $TPL$grant execute on function __P__.room_360_save(jsonb) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'room_360:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
