-- Branches (feature branches, off unless switched on): a business with several branches (its centres, pangea_locations) gives
-- each staff member one or more branches (staff.branches). They see only the customers and staff of their branches. Staff with
-- no branch set (the owner and the big bosses) see everything, with a branch filter in the app. Customers are shared: each has a
-- home branch (customers.home_branch), set by the staff who adds them, and one file that works at any branch. A customer with
-- no home branch is seen by every branch. Coaches still see every client they coach, whatever the branch.

alter table public.staff add column if not exists branches uuid[];
alter table public.customers add column if not exists home_branch uuid references public.pangea_locations (id) on delete set null;
create index if not exists customers_home_branch on public.customers (home_branch) where home_branch is not null;
grant select (branches), insert (branches), update (branches) on public.staff to authenticated;
grant select (home_branch), insert (home_branch), update (home_branch) on public.customers to authenticated;

-- my branches: null means all branches (feature off, or a staff member with no branch set); empty means none (not staff)
create or replace function private.my_branches() returns uuid[] language plpgsql stable security definer set search_path to '' as $f$
declare b uuid[]; ok boolean;
begin
  if not private.feature('branches', false) then return null; end if;
  select s.branches, true into b, ok from public.staff s where s.user_id = auth.uid() and s.active limit 1;
  if not coalesce(ok, false) then return '{}'::uuid[]; end if;
  return case when coalesce(cardinality(b), 0) = 0 then null else b end;
end $f$;
create or replace function private.branch_ok(p_branch uuid) returns boolean language sql stable security definer set search_path to '' as $f$
  select p_branch is null or private.my_branches() is null or p_branch = any (private.my_branches())
$f$;
create or replace function private.branch_can(p_customer uuid) returns boolean language sql stable security definer set search_path to '' as $f$
  select private.branch_ok((select c.home_branch from public.customers c where c.id = p_customer))
$f$;
grant usage on schema private to authenticated;
grant execute on function private.my_branches(), private.branch_ok(uuid), private.branch_can(uuid) to authenticated;

-- the branches, for the app (any signed in staff member)
create or replace function public.branches_list() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by l.sort, l.name), '[]'::jsonb)
  from public.pangea_locations l where private.my_staff_id() is not null
$f$;
create or replace function public.my_branches() returns jsonb language sql stable security definer set search_path to '' as $f$
  select to_jsonb(private.my_branches())
$f$;
revoke all on function public.branches_list(), public.my_branches() from public, anon;
grant execute on function public.branches_list(), public.my_branches() to authenticated;

-- a customer added by staff of one branch belongs to that branch
create or replace function private.customer_branch_default() returns trigger language plpgsql security definer set search_path to '' as $f$
declare b uuid[];
begin
  if new.home_branch is null and private.feature('branches', false) then
    b := private.my_branches();
    if cardinality(b) = 1 then new.home_branch := b[1]; end if;
  end if;
  return new;
end $f$;
drop trigger if exists customer_branch_default on public.customers;
create trigger customer_branch_default before insert on public.customers for each row execute function private.customer_branch_default();

-- the rules: only rows of my branches (customers: plus my own row; staff: plus staff of every branch, and me)
drop policy if exists customers_branch on public.customers;
create policy customers_branch on public.customers as restrictive for select to authenticated
  using (user_id = (select auth.uid()) or home_branch is null or (select private.my_branches()) is null or home_branch = any ((select private.my_branches())::uuid[]));
drop policy if exists customers_branch_update on public.customers;
create policy customers_branch_update on public.customers as restrictive for update to authenticated
  using (user_id = (select auth.uid()) or home_branch is null or (select private.my_branches()) is null or home_branch = any ((select private.my_branches())::uuid[]));
drop policy if exists staff_branch on public.staff;
create policy staff_branch on public.staff as restrictive for select to authenticated
  using (user_id = (select auth.uid()) or coalesce(cardinality(branches), 0) = 0 or (select private.my_branches()) is null or branches && (select private.my_branches()));

-- coaching: a branch manager sees the members of their branch (and coaches still see their own clients)
do $p$
declare d text; n text;
begin
  if to_regprocedure('private.coach_can(uuid)') is not null then
    d := pg_get_functiondef('private.coach_can(uuid)'::regprocedure);
    if position('branch_can' in d) = 0 then
      n := replace(d, $x$select coalesce(private.staff_role(),'') = 'manager'$x$, $x$select (coalesce(private.staff_role(),'') = 'manager' and private.branch_can(p_customer))$x$);
      if n = d then raise notice 'coach_can: older version, skipped'; else execute n;
        if position('branch_can' in pg_get_functiondef('private.coach_can(uuid)'::regprocedure)) = 0 then raise exception 'coach_can patch did not apply'; end if; end if;
    end if;
  end if;
  if to_regprocedure('public.coach_clients_list()') is not null then
    d := pg_get_functiondef('public.coach_clients_list()'::regprocedure);
    if position('branch_can' in d) = 0 then
      n := replace(d, $x$(mgr or cc.staff_id=v_me)$x$, $x$((mgr and private.branch_can(c.id)) or cc.staff_id=v_me)$x$);
      if n = d then raise notice 'coach_clients_list: older version, skipped'; else execute n;
        if position('branch_can' in pg_get_functiondef('public.coach_clients_list()'::regprocedure)) = 0 then raise exception 'coach_clients_list patch did not apply'; end if; end if;
    end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
