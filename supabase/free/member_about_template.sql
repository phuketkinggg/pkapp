delete from mf.template where name like 'member_about:%';
insert into mf.template (ord, phase, kind, name, sql) values (302701, 3, 'patch', 'member_about:302701', $TPL$alter table __P__.member_file add column if not exists about jsonb not null default '{}'::jsonb;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302702, 3, 'patch', 'member_about:302702', $TPL$alter table __P__.member_file add column if not exists intake_at timestamptz;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402801, 4, 'patch', 'member_about:402801', $TPL$create or replace function __Q__.about_clean(p jsonb) returns jsonb language plpgsql immutable set search_path to '' as $f$
declare k text; v text; out jsonb := '{}'::jsonb; d date;
begin
  if jsonb_typeof(p) <> 'object' then return out; end if;
  foreach k in array array['birth','sex','height','blood','activity','sleep','smoke','alcohol','diet','family','doctor'] loop
    if not p ? k then continue; end if;
    v := left(btrim(coalesce(p->>k, '')), case when k = 'family' then 2000 else 200 end);
    if k = 'birth' and v <> '' then
      begin d := v::date; exception when others then d := null; end;
      if d is null or d < date '1900-01-01' or d > current_date then v := ''; else v := d::text; end if;
    end if;
    out := out || jsonb_build_object(k, v);
  end loop;
  return out;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402802, 4, 'patch', 'member_about:402802', $TPL$create or replace function __P__.my_file_about(p jsonb, p_done boolean) returns void
language plpgsql security definer set search_path to '' as $f$
declare cid uuid := __Q__.customer_id(); a jsonb := __Q__.about_clean(coalesce(p, '{}'::jsonb)); cons timestamptz;
begin
  if cid is null then raise exception 'Sign in first.'; end if;
  select consent_at into cons from __P__.member_file where customer_id = cid;
  if cons is null and exists (select 1 from jsonb_each_text(a) x where x.value <> '') then raise exception 'Agree to us keeping your health details first.'; end if;
  insert into __P__.member_file as f (customer_id, about, intake_at, updated_at, updated_by)
    values (cid, (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(a) x where x.value <> '""'::jsonb), case when p_done then now() end, now(), 'Member')
  on conflict (customer_id) do update set
    about = (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(f.about || a) x where x.value <> '""'::jsonb),
    intake_at = case when p_done then coalesce(f.intake_at, now()) else f.intake_at end,
    updated_at = now(), updated_by = 'Member';
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196801, 11, 'patch', 'member_about:1196801', $TPL$revoke all on function __P__.my_file_about(jsonb, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196802, 11, 'patch', 'member_about:1196802', $TPL$grant execute on function __P__.my_file_about(jsonb, boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402803, 4, 'patch', 'member_about:402803', $TPL$create or replace function __P__.member_file_about_save(p_customer uuid, p jsonb) returns void
language plpgsql security definer set search_path to '' as $f$
declare me uuid := __Q__.my_staff_id(); nm text; a jsonb := __Q__.about_clean(coalesce(p, '{}'::jsonb));
begin
  if me is null or not __Q__.health_can(p_customer) then raise exception 'Not allowed.'; end if;
  select name into nm from __P__.staff where id = me;
  insert into __P__.member_file as f (customer_id, about, updated_at, updated_by) values (p_customer, (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(a) x where x.value <> '""'::jsonb), now(), nm)
  on conflict (customer_id) do update set
    about = (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(f.about || a) x where x.value <> '""'::jsonb),
    updated_at = now(), updated_by = nm;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196803, 11, 'patch', 'member_about:1196803', $TPL$revoke all on function __P__.member_file_about_save(uuid, jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196804, 11, 'patch', 'member_about:1196804', $TPL$grant execute on function __P__.member_file_about_save(uuid, jsonb) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001401, 10, 'patch', 'member_about:1001401', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.my_file()') is null then raise notice 'no member file here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.my_file()'::regprocedure);
  if position('ask_intake' in d) > 0 then raise notice 'my_file already patched'; return; end if;
  n := replace(d, $x$    'coaches', coalesce($x$,
    $x$    'ask_intake', __Q__.feature('health_intake', true) and not exists (select 1 from __P__.member_file f2 where f2.customer_id = cid and f2.intake_at is not null),
    'coaches', coalesce($x$);
  if n = d then raise notice 'my_file: older version, skipped'; return; end if;
  execute n;
  if position('ask_intake' in pg_get_functiondef('__P__.my_file()'::regprocedure)) = 0 then raise exception 'my_file patch did not apply'; end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'member_about:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
