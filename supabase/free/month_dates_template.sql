delete from mf.template where name like 'month_dates:%';
insert into mf.template (ord, phase, kind, name, sql) values (405001, 4, 'patch', 'month_dates:405001', $TPL$create or replace function __Q__.month_count(p_days int) returns int language sql immutable set search_path = '' as $f$
  select case when p_days >= 28 and abs(p_days - round(p_days / 30.4375) * 30.4375) <= 3.5 then round(p_days / 30.4375)::int end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405002, 4, 'patch', 'month_dates:405002', $TPL$create or replace function __Q__.month_dates() returns trigger language plpgsql set search_path = '' as $f$
declare m int;
begin
  if new.starts_on is null or new.expires_on is null or new.duration_days is null then return new; end if;
  if new.stay_id is not null or new.for_stay is not null then return new; end if;
  if new.expires_on <> new.starts_on + new.duration_days - 1 then return new; end if;
  if tg_op = 'UPDATE' and old.starts_on is not distinct from new.starts_on and old.expires_on is not distinct from new.expires_on
     and old.duration_days is not distinct from new.duration_days then return new; end if;
  m := __Q__.month_count(new.duration_days);
  if m is null or not __Q__.feature('month_dates', true) then return new; end if;
  new.expires_on := (new.starts_on + make_interval(months => m))::date;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199101, 11, 'patch', 'month_dates:1199101', $TPL$revoke all on function __Q__.month_count(int), __Q__.month_dates() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903201, 9, 'patch', 'month_dates:903201', $TPL$drop trigger if exists purchases_month_dates on __P__.purchases;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903202, 9, 'patch', 'month_dates:903202', $TPL$create trigger purchases_month_dates before insert or update of starts_on, expires_on, duration_days on __P__.purchases
  for each row execute function __Q__.month_dates();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003601, 10, 'patch', 'month_dates:1003601', $TPL$update __P__.purchases p set expires_on = (p.starts_on + make_interval(months => __Q__.month_count(p.duration_days)))::date
where __Q__.feature('month_dates', true) and not coalesce(p.cancelled, false) and p.refunded_at is null
  and p.stay_id is null and p.for_stay is null
  and p.starts_on is not null and p.duration_days is not null and __Q__.month_count(p.duration_days) is not null
  and p.expires_on = p.starts_on + p.duration_days - 1 and p.expires_on >= (now() at time zone 'Asia/Bangkok')::date
  and (p.starts_on + make_interval(months => __Q__.month_count(p.duration_days)))::date > p.expires_on;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'month_dates:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
