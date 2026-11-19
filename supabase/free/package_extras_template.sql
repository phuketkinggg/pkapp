delete from mf.template where name like 'package_extras:%';
insert into mf.template (ord, phase, kind, name, sql) values (303551, 3, 'patch', 'package_extras:303551', $TPL$alter table __P__.packages add column if not exists extra_ids uuid[] not null default '{}';$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403731, 4, 'patch', 'package_extras:403731', $TPL$create or replace function __Q__.package_addon_ids(p_pkg uuid) returns uuid[]
language plpgsql stable security definer set search_path to '' as $$
declare k __P__.packages; ids uuid[];
begin
  select * into k from __P__.packages where id = p_pkg;
  if k.id is null then return '{}'::uuid[]; end if;
  if __Q__.feature('package_extras', true) and coalesce(array_length(k.extra_ids, 1), 0) > 0 then
    select array_agg(x.id order by x.n) into ids from unnest(k.extra_ids) with ordinality x(id, n)
      join __P__.packages e on e.id = x.id and e.id <> k.id and e.active and coalesce(e.price_thb, 0) >= 1 and coalesce(e.audience, 'all') = 'all';
    return coalesce(ids, '{}'::uuid[]);
  end if;
  if 'Privates' = any (coalesce(k.covers, '{}')) then return __Q__.private_addon_ids(); end if;
  return '{}'::uuid[];
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403732, 4, 'patch', 'package_extras:403732', $TPL$create or replace function __P__.package_addons(p_package uuid) returns jsonb
language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'price', k.price_thb, 'note', nullif(btrim(coalesce(k.notes, '')), ''),
      'qty', coalesce(k.visit_limit, 0) = 1 or coalesce(k.covers, '{}') = '{}', 'spa', coalesce(k.covers, '{}') = '{Spa}') order by x.n), '[]'::jsonb)
  from unnest(__Q__.package_addon_ids(p_package)) with ordinality x(id, n) join __P__.packages k on k.id = x.id
$$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403733, 4, 'patch', 'package_extras:403733', $TPL$create or replace function __Q__.web_addons(p jsonb, p_pkg uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare ids uuid[] := __Q__.package_addon_ids(p_pkg); e jsonb; k __P__.packages; q int; out jsonb := '[]'::jsonb; seen uuid[] := '{}';
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then return null; end if;
  if jsonb_array_length(p) > 12 then raise exception 'Choose up to 12 extras.'; end if;
  for e in select * from jsonb_array_elements(p) loop
    begin select * into k from __P__.packages where id = (e->>'package_id')::uuid; exception when others then raise exception 'Choose the extras again.'; end;
    if k.id is null or not (k.id = any(ids)) then raise exception 'That extra is not available online any more. Choose again, or WhatsApp us.'; end if;
    if k.id = any(seen) then continue; end if; seen := seen || k.id;
    q := coalesce(nullif(e->>'qty','')::int, 1);
    if not (coalesce(k.visit_limit, 0) = 1 or coalesce(k.covers, '{}') = '{}') then q := 1; end if;
    if q < 1 or q > 20 then raise exception 'Choose between 1 and 20 of each extra.'; end if;
    out := out || jsonb_build_object('package_id', k.id, 'name', k.name, 'qty', q, 'price', k.price_thb * q,
      'label', regexp_replace(k.name, '^Spa Access,\s*', 'Recovery, ') || case when q > 1 then ' x ' || q else '' end);
  end loop;
  return nullif(out, '[]'::jsonb);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197731, 11, 'patch', 'package_extras:1197731', $TPL$revoke all on function __Q__.package_addon_ids(uuid), __Q__.web_addons(jsonb, uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197732, 11, 'patch', 'package_extras:1197732', $TPL$revoke all on function __P__.package_addons(uuid) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197733, 11, 'patch', 'package_extras:1197733', $TPL$grant execute on function __P__.package_addons(uuid) to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002251, 10, 'patch', 'package_extras:1002251', $TPL$do $patch$
declare s text; n text; a text := $a$  ad := __Q__.web_addons(p->'addons');
  if ad is not null and not ('Privates' = any (coalesce(k.covers,'{}'))) then raise exception 'Add-ons can be added to privates here.'; end if;$a$;
begin
  if to_regprocedure('__P__.web_pkg_order(jsonb)') is null then raise notice 'package_extras: no web_pkg_order here, skipped'; return; end if;
  s := pg_get_functiondef('__P__.web_pkg_order(jsonb)'::regprocedure);
  if s like '%web_addons(p->''addons'', k.id)%' then return; end if;
  if position(a in s) = 0 then raise notice 'package_extras: web_pkg_order is a different version here, skipped'; return; end if;
  n := replace(s, a, $a$  ad := __Q__.web_addons(p->'addons', k.id);$a$);
  if n not like '%web_addons(p->''addons'', k.id)%' then raise exception 'package_extras: patch did not apply'; end if;
  execute n;
end $patch$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'package_extras:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
