delete from mf.template where name like 'branches:%';
insert into mf.template (ord, phase, kind, name, sql) values (302901, 3, 'patch', 'branches:302901', $TPL$alter table __P__.staff add column if not exists branches uuid[];$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302902, 3, 'patch', 'branches:302902', $TPL$alter table __P__.customers add column if not exists home_branch uuid references __P__.pangea_locations (id) on delete set null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001601, 10, 'patch', 'branches:1001601', $TPL$create index if not exists customers_home_branch on __P__.customers (home_branch) where home_branch is not null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197001, 11, 'patch', 'branches:1197001', $TPL$grant select (branches), insert (branches), update (branches) on __P__.staff to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197002, 11, 'patch', 'branches:1197002', $TPL$grant select (home_branch), insert (home_branch), update (home_branch) on __P__.customers to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403001, 4, 'patch', 'branches:403001', $TPL$create or replace function __Q__.my_branches() returns uuid[] language plpgsql stable security definer set search_path to '' as $f$
declare b uuid[]; ok boolean;
begin
  if not __Q__.feature('branches', false) then return null; end if;
  select s.branches, true into b, ok from __P__.staff s where s.user_id = auth.uid() and s.active limit 1;
  if not coalesce(ok, false) then return '{}'::uuid[]; end if;
  return case when coalesce(cardinality(b), 0) = 0 then null else b end;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403002, 4, 'patch', 'branches:403002', $TPL$create or replace function __Q__.branch_ok(p_branch uuid) returns boolean language sql stable security definer set search_path to '' as $f$
  select p_branch is null or __Q__.my_branches() is null or p_branch = any (__Q__.my_branches())
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403003, 4, 'patch', 'branches:403003', $TPL$create or replace function __Q__.branch_can(p_customer uuid) returns boolean language sql stable security definer set search_path to '' as $f$
  select __Q__.branch_ok((select c.home_branch from __P__.customers c where c.id = p_customer))
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197003, 11, 'patch', 'branches:1197003', $TPL$grant usage on schema __Q__ to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197004, 11, 'patch', 'branches:1197004', $TPL$grant execute on function __Q__.my_branches(), __Q__.branch_ok(uuid), __Q__.branch_can(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403004, 4, 'patch', 'branches:403004', $TPL$create or replace function __P__.branches_list() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by l.sort, l.name), '[]'::jsonb)
  from __P__.pangea_locations l where __Q__.my_staff_id() is not null
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403005, 4, 'patch', 'branches:403005', $TPL$create or replace function __P__.my_branches() returns jsonb language sql stable security definer set search_path to '' as $f$
  select to_jsonb(__Q__.my_branches())
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197005, 11, 'patch', 'branches:1197005', $TPL$revoke all on function __P__.branches_list(), __P__.my_branches() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197006, 11, 'patch', 'branches:1197006', $TPL$grant execute on function __P__.branches_list(), __P__.my_branches() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403006, 4, 'patch', 'branches:403006', $TPL$create or replace function __Q__.customer_branch_default() returns trigger language plpgsql security definer set search_path to '' as $f$
declare b uuid[];
begin
  if new.home_branch is null and __Q__.feature('branches', false) then
    b := __Q__.my_branches();
    if cardinality(b) = 1 then new.home_branch := b[1]; end if;
  end if;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901201, 9, 'patch', 'branches:901201', $TPL$drop trigger if exists customer_branch_default on __P__.customers;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901202, 9, 'patch', 'branches:901202', $TPL$create trigger customer_branch_default before insert on __P__.customers for each row execute function __Q__.customer_branch_default();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001602, 10, 'patch', 'branches:1001602', $TPL$drop policy if exists customers_branch on __P__.customers;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001603, 10, 'patch', 'branches:1001603', $TPL$create policy customers_branch on __P__.customers as restrictive for select to authenticated
  using (user_id = (select auth.uid()) or home_branch is null or (select __Q__.my_branches()) is null or home_branch = any ((select __Q__.my_branches())::uuid[]));$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001604, 10, 'patch', 'branches:1001604', $TPL$drop policy if exists customers_branch_update on __P__.customers;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001605, 10, 'patch', 'branches:1001605', $TPL$create policy customers_branch_update on __P__.customers as restrictive for update to authenticated
  using (user_id = (select auth.uid()) or home_branch is null or (select __Q__.my_branches()) is null or home_branch = any ((select __Q__.my_branches())::uuid[]));$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001606, 10, 'patch', 'branches:1001606', $TPL$drop policy if exists staff_branch on __P__.staff;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001607, 10, 'patch', 'branches:1001607', $TPL$create policy staff_branch on __P__.staff as restrictive for select to authenticated
  using (user_id = (select auth.uid()) or coalesce(cardinality(branches), 0) = 0 or (select __Q__.my_branches()) is null or branches && (select __Q__.my_branches()));$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1001608, 10, 'patch', 'branches:1001608', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__Q__.coach_can(uuid)') is not null then
    d := pg_get_functiondef('__Q__.coach_can(uuid)'::regprocedure);
    if position('branch_can' in d) = 0 then
      n := replace(d, $x$select coalesce(__Q__.staff_role(),'') = 'manager'$x$, $x$select (coalesce(__Q__.staff_role(),'') = 'manager' and __Q__.branch_can(p_customer))$x$);
      if n = d then raise notice 'coach_can: older version, skipped'; else execute n;
        if position('branch_can' in pg_get_functiondef('__Q__.coach_can(uuid)'::regprocedure)) = 0 then raise exception 'coach_can patch did not apply'; end if; end if;
    end if;
  end if;
  if to_regprocedure('__P__.coach_clients_list()') is not null then
    d := pg_get_functiondef('__P__.coach_clients_list()'::regprocedure);
    if position('branch_can' in d) = 0 then
      n := replace(d, $x$(mgr or cc.staff_id=v_me)$x$, $x$((mgr and __Q__.branch_can(c.id)) or cc.staff_id=v_me)$x$);
      if n = d then raise notice 'coach_clients_list: older version, skipped'; else execute n;
        if position('branch_can' in pg_get_functiondef('__P__.coach_clients_list()'::regprocedure)) = 0 then raise exception 'coach_clients_list patch did not apply'; end if; end if;
    end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'branches:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
