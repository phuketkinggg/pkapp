delete from mf.template where name like 'stay_move_extras:%';
insert into mf.template (ord, phase, kind, name, sql) values (405301, 4, 'patch', 'stay_move_extras:405301', $TPL$create or replace function __Q__.stay_move_extras() returns trigger language plpgsql security definer set search_path = '' as $f$
declare shift int := new.check_in - old.check_in;
begin
  if (new.check_in = old.check_in and new.check_out = old.check_out) or not __Q__.feature('stay_move_extras', true) then return new; end if;
  update __P__.purchases k set
    starts_on = case when k.starts_on is null then null else k.starts_on + shift end,
    expires_on = case when k.expires_on is null then null
      when k.expires_on between old.check_out - 1 and old.check_out then new.check_out - (old.check_out - k.expires_on)
      else k.expires_on + shift end,
    duration_days = case when k.duration_days is not null and k.expires_on between old.check_out - 1 and old.check_out then greatest(1, new.check_out - new.check_in) else k.duration_days end
  where (k.for_stay = new.id or k.stay_id = new.id) and not coalesce(k.cancelled, false)
    and k.package_name <> 'Stay: group Muay Thai included'
    and k.starts_on is not distinct from old.check_in;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199401, 11, 'patch', 'stay_move_extras:1199401', $TPL$revoke all on function __Q__.stay_move_extras() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903501, 9, 'patch', 'stay_move_extras:903501', $TPL$drop trigger if exists stays_move_extras on __P__.stays;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903502, 9, 'patch', 'stay_move_extras:903502', $TPL$create trigger stays_move_extras after update of check_in, check_out on __P__.stays
  for each row execute function __Q__.stay_move_extras();$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'stay_move_extras:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
