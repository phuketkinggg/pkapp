delete from mf.template where name like 'private_group_price:%';
insert into mf.template (ord, phase, kind, name, sql) values (303401, 3, 'patch', 'private_group_price:303401', $TPL$alter table __P__.packages add column if not exists group_prices jsonb;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303402, 3, 'patch', 'private_group_price:303402', $TPL$alter table __P__.packages add column if not exists badge text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303403, 3, 'patch', 'private_group_price:303403', $TPL$alter table __P__.packages add column if not exists was_thb integer;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303404, 3, 'patch', 'private_group_price:303404', $TPL$alter table __P__.purchases add column if not exists people smallint;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303405, 3, 'patch', 'private_group_price:303405', $TPL$alter table __P__.purchases add column if not exists coaches smallint;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403501, 4, 'patch', 'private_group_price:403501', $TPL$create or replace function __Q__.group_ratio(p_package uuid, p_people integer, p_coaches integer) returns numeric
language sql stable security definer set search_path to '' as $f$
  select case when coalesce(p_people, 1) = 1 and coalesce(p_coaches, 1) = 1 then 1::numeric
    when not __Q__.feature('private_group_price', true) then null
    else (select (g->>'price')::numeric from jsonb_array_elements(coalesce(k.group_prices, '[]'::jsonb)) g
          where (g->>'people')::int = p_people and (g->>'coaches')::int = p_coaches limit 1)
       / nullif(coalesce(__Q__.tier_unit(k.tiers, 1)::numeric, k.price_thb::numeric / greatest(coalesce(k.visit_limit, 1), 1)), 0) end
  from __P__.packages k where k.id = p_package
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403502, 4, 'patch', 'private_group_price:403502', $TPL$create or replace function __Q__.group_label(p_people integer, p_coaches integer) returns text language sql immutable as $f$
  select p_people || case when p_people = 1 then ' person, ' else ' people, ' end || p_coaches || case when p_coaches = 1 then ' coach' else ' coaches' end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403503, 4, 'patch', 'private_group_price:403503', $TPL$create or replace function __P__.customer_buy_group(p_package uuid, p_fz boolean, p_qty integer, p_people integer, p_coaches integer) returns uuid
language plpgsql security definer set search_path to '' as $f$
declare k __P__.packages; r numeric; v_id uuid; grp text; addon integer := 0; pr __P__.purchases;
begin
  if coalesce(p_people, 1) not between 1 and 20 or coalesce(p_coaches, 1) not between 1 and 10 then raise exception 'Choose how many people and coaches.'; end if;
  select * into k from __P__.packages where id = p_package and active;
  if not found then raise exception 'That package is not on sale.'; end if;
  r := __Q__.group_ratio(p_package, coalesce(p_people, 1), coalesce(p_coaches, 1));
  if r is null then raise exception 'That number of people and coaches is not on sale. Ask at the front desk.'; end if;
  grp := coalesce((select price_group from __P__.customers where id = __Q__.customer_id()), 'standard');
  if jsonb_array_length(coalesce(__Q__.tiers_for(k.tiers, k.tiers_local, grp), '[]'::jsonb)) > 0 then
    v_id := __P__.customer_buy_qty(p_package, p_fz, p_qty);
  else
    v_id := __P__.customer_buy(p_package, p_fz);
  end if;
  if coalesce(p_people, 1) > 1 or coalesce(p_coaches, 1) > 1 then
    select * into pr from __P__.purchases where id = v_id;
    if coalesce(p_fz, false) then addon := coalesce(__Q__.addon_for(k.addon_fz_thb, k.addon_fz_local_thb, grp), 0); end if;
    update __P__.purchases set
      price_thb = (round((pr.price_thb - addon) * r / 10) * 10)::int + addon,
      package_name = replace(pr.package_name, ' + Fitness Zone', '') || ', ' || __Q__.group_label(p_people, p_coaches) || case when coalesce(p_fz, false) then ' + Fitness Zone' else '' end,
      people = p_people, coaches = p_coaches
    where id = v_id;
  end if;
  return v_id;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197501, 11, 'patch', 'private_group_price:1197501', $TPL$revoke all on function __P__.customer_buy_group(uuid, boolean, integer, integer, integer) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197502, 11, 'patch', 'private_group_price:1197502', $TPL$grant execute on function __P__.customer_buy_group(uuid, boolean, integer, integer, integer) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002101, 10, 'patch', 'private_group_price:1002101', $TPL$do $p$
declare d text; n text;
begin
  foreach d in array array['__P__.customer_home()', '__P__.customer_home_as(uuid)'] loop
    if to_regprocedure(d) is null then continue; end if;
    n := pg_get_functiondef(d::regprocedure);
    if position('group_prices' in n) > 0 then continue; end if;
    if position($x$'qty_unit', g.qty_unit)$x$ in n) = 0 then raise notice '% older version, skipped', d; continue; end if;
    execute replace(n, $x$'qty_unit', g.qty_unit)$x$, $x$'qty_unit', g.qty_unit, 'group_prices', case when __Q__.feature('private_group_price', true) then g.group_prices end)$x$);
    if position('group_prices' in pg_get_functiondef(d::regprocedure)) = 0 then raise exception '% patch did not apply', d; end if;
  end loop;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'private_group_price:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
