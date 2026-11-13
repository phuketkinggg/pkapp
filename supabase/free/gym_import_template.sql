delete from mf.template where name like 'gym_import:%';
insert into mf.template (ord, phase, kind, name, sql) values (303101, 3, 'patch', 'gym_import:303101', $TPL$alter table __P__.customers add column if not exists ext_id text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001801, 10, 'patch', 'gym_import:1001801', $TPL$create index if not exists customers_ext_id on __P__.customers (ext_id) where ext_id is not null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197201, 11, 'patch', 'gym_import:1197201', $TPL$grant select (ext_id), insert (ext_id), update (ext_id) on __P__.customers to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403201, 4, 'patch', 'gym_import:403201', $TPL$create or replace function __Q__.digits(t text) returns text language sql immutable as $f$
  select nullif(regexp_replace(coalesce(t, ''), '[^0-9]', '', 'g'), '')
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403202, 4, 'patch', 'gym_import:403202', $TPL$create or replace function __P__.import_members(p_rows jsonb, p_from text, p_save boolean) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare r jsonb; i int := 0; cid uuid; nm text; em text; ph text; ex text; pk text; st date; en date; vl int; pkg __P__.packages; src text := left(coalesce(nullif(btrim(p_from), ''), 'the old system'), 60);
  n_new int := 0; n_upd int := 0; n_pk int := 0; skipped jsonb := '[]'::jsonb; isnew boolean;
begin
  if not __Q__.feature('gym_import', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No members found in the file.'; end if;
  if jsonb_array_length(p_rows) > 20000 then raise exception 'The file has too many lines.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    nm := left(btrim(coalesce(r->>'name', '')), 120); em := lower(left(btrim(coalesce(r->>'email', '')), 200)); ph := left(btrim(coalesce(r->>'phone', '')), 30); ex := left(nullif(btrim(coalesce(r->>'ext_id', '')), ''), 120);
    if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then em := ''; end if;
    if nm = '' and em = '' and ph = '' then skipped := skipped || jsonb_build_object('line', i, 'why', 'No name, email or phone'); continue; end if;
    if nm = '' then nm := coalesce(nullif(split_part(em, '@', 1), ''), ph); end if;
    cid := null;
    if ex is not null then select id into cid from __P__.customers where ext_id = ex limit 1; end if;
    if cid is null and em <> '' then select id into cid from __P__.customers where lower(email) = em order by created_at limit 1; end if;
    if cid is null and length(coalesce(__Q__.digits(ph), '')) >= 7 then select id into cid from __P__.customers where __Q__.digits(phone) = __Q__.digits(ph) order by created_at limit 1; end if;
    isnew := cid is null;
    if p_save then
      if isnew then
        insert into __P__.customers (name, email, phone, notes, ext_id, tags)
          values (nm, nullif(em, ''), nullif(ph, ''), nullif(left(btrim(coalesce(r->>'notes', '')), 2000), ''), ex, array['imported'])
          returning id into cid;
      else
        update __P__.customers set email = coalesce(email, nullif(em, '')), phone = coalesce(phone, nullif(ph, '')), ext_id = coalesce(ext_id, ex) where id = cid;
      end if;
    end if;
    if isnew then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    -- their current package
    pk := left(nullif(btrim(coalesce(r->>'package', '')), ''), 120);
    begin st := nullif(r->>'starts', '')::date; exception when others then st := null; end;
    begin en := nullif(r->>'expires', '')::date; exception when others then en := null; end;
    begin vl := round(nullif(r->>'visits_left', '')::numeric); exception when others then vl := null; end;
    if pk is not null and (en is null or en >= __Q__.bkk_today() - 1) and coalesce(vl, 1) > 0 then
      select * into pkg from __P__.packages where lower(name) = lower(pk) limit 1;
      if pkg.id is null then select * into pkg from __P__.packages where name ilike '%' || pk || '%' order by price_thb desc nulls last limit 1; end if;
      if p_save then
        if not exists (select 1 from __P__.purchases k where k.customer_id = cid and k.package_name = pk and k.expires_on is not distinct from en and not coalesce(k.cancelled, false)) then
          insert into __P__.purchases (customer_id, package_id, package_name, price_thb, paid, method, purchased_on, starts_on, expires_on, visits_left, visit_limit, covers, per_week_limit)
          values (cid, pkg.id, pk, 0, true, null, coalesce(st, __Q__.bkk_today()), coalesce(st, __Q__.bkk_today()), en, vl, coalesce(vl, pkg.visit_limit), coalesce(pkg.covers, array['Muay Thai']), pkg.per_week_limit);
          n_pk := n_pk + 1;
        end if;
      else
        n_pk := n_pk + 1;
      end if;
      pkg := null;
    end if;
  end loop;
  if p_save then
    insert into __P__.app_settings (key, value) values ('migrate', jsonb_build_object('from', src, 'last_import', now(), 'rows', i)::text)
      on conflict (key) do update set value = ((coalesce(nullif(__P__.app_settings.value, ''), '{}')::jsonb) || jsonb_build_object('from', src, 'last_import', now(), 'rows', i))::text, updated_at = now();
  end if;
  return jsonb_build_object('rows', i, 'new', n_new, 'updated', n_upd, 'packages', n_pk, 'skipped', skipped, 'saved', coalesce(p_save, false));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197202, 11, 'patch', 'gym_import:1197202', $TPL$revoke all on function __P__.import_members(jsonb, text, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197203, 11, 'patch', 'gym_import:1197203', $TPL$grant execute on function __P__.import_members(jsonb, text, boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001802, 10, 'patch', 'gym_import:1001802', $TPL$do $p$
declare d text; n text; fn text; pat text;
begin
  foreach fn in array array['__Q__.pkg_welcome_queue()', '__Q__.course_welcome_queue()'] loop
    if to_regprocedure(fn) is null then continue; end if;
    d := pg_get_functiondef(fn::regprocedure);
    if position('alongside' in d) > 0 then continue; end if;
    pat := case when fn like '%pkg%' then $x$if not __Q__.feature('pkg_welcome', true) then return new; end if;$x$ else $x$if not __Q__.feature('course_welcome', true) then return new; end if;$x$ end;
    n := replace(d, pat, replace(pat, 'then return new;', 'or __Q__.feature(''alongside'', false) then return new;'));
    if n = d then raise notice '% older version, skipped', fn; continue; end if;
    execute n;
    if position('alongside' in pg_get_functiondef(fn::regprocedure)) = 0 then raise exception '% patch did not apply', fn; end if;
  end loop;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'gym_import:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
