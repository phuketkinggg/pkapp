-- Accounts: the owner adds businesses and departments.
-- app_settings 'acc_structure' = {"businesses":[{"name":..., "depts":[...]}]}.
-- Phuket King Gym and Pangea Resort are built in (the app sorts their sales by itself) and their automatic departments stay.
-- Packages, shop categories and tills can be sent to any business and department, so a new business gets its own sales.

insert into public.app_settings(key, value) values ('acc_structure', '{"businesses":[{"name":"Phuket King Gym","depts":["Gym training","Privates","Spa","Visa and DTV","Gym shop","Gym","Office","Marketing","Maintenance","Other"]},{"name":"Pangea Resort","depts":["Rooms","Pangea Cafe","Pangea Resort","Housekeeping","Maintenance","Office","Marketing","Other"]}]}')
on conflict (key) do nothing;

alter table public.packages add column if not exists acc_business text;
alter table public.packages add column if not exists acc_department text;
alter table public.shop_categories add column if not exists acc_business text;
alter table public.shop_categories add column if not exists acc_department text;
alter table public.shop_locations add column if not exists acc_business text;
alter table public.shop_locations add column if not exists acc_department text;
alter table public.places drop constraint if exists places_business_check;

create or replace function private.acc_struct() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'acc_structure'), '{"businesses":[]}'::jsonb)
$$;
create or replace function private.acc_businesses() returns text[] language sql stable security definer set search_path to '' as $$
  select array(select distinct x from (select 'Phuket King Gym' x union all select 'Pangea Resort' union all select b->>'name' from jsonb_array_elements(private.acc_struct()->'businesses') b) q where coalesce(x,'') <> '')
$$;
create or replace function private.acc_locked(p_b text) returns text[] language sql immutable set search_path to '' as $$
  select case p_b when 'Phuket King Gym' then array['Gym training','Privates','Spa','Visa and DTV','Gym shop'] when 'Pangea Resort' then array['Rooms','Pangea Cafe'] else array[]::text[] end
$$;
revoke all on function private.acc_struct() from public, anon, authenticated;
revoke all on function private.acc_businesses() from public, anon, authenticated;

-- everyone on the team reads it (the receipt form lists the departments); the sales links only for money people
create or replace function public.acc_structure() returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  return private.acc_struct() || jsonb_build_object('builtin', jsonb_build_array('Phuket King Gym','Pangea Resort'),
    'locked', jsonb_build_object('Phuket King Gym', to_jsonb(private.acc_locked('Phuket King Gym')), 'Pangea Resort', to_jsonb(private.acc_locked('Pangea Resort'))),
    'links', case when private.can('money') and coalesce(private.staff_role(),'') = 'manager' then jsonb_build_object(
      'packages', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'b',acc_business,'d',acc_department) order by name) from public.packages where active), '[]'::jsonb),
      'categories', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'b',acc_business,'d',acc_department) order by sort, name) from public.shop_categories where active), '[]'::jsonb),
      'tills', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'b',acc_business,'d',acc_department) order by sort, name) from public.shop_locations where active), '[]'::jsonb)) end);
end $$;
revoke all on function public.acc_structure() from public, anon;
grant execute on function public.acc_structure() to authenticated;

-- add or change one business: {old, name, depts:[...]}
create or replace function public.acc_business_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
declare s jsonb := private.acc_struct(); old text := nullif(btrim(coalesce(p->>'old','')),''); nm text := btrim(coalesce(p->>'name',''));
  deps text[]; lst jsonb := '[]'::jsonb; b jsonb; found_it boolean := false; missing text;
begin
  if not private.can('money') or coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin with money access can change businesses.'; end if;
  if nm = '' then raise exception 'Give the business a name.'; end if;
  if length(nm) > 60 then raise exception 'Keep the name under 60 letters.'; end if;
  select array_agg(distinct d) into deps from (select left(btrim(x),60) d from jsonb_array_elements_text(coalesce(p->'depts','[]'::jsonb)) x) q where d <> '';
  deps := coalesce(deps, array[]::text[]);
  if old in ('Phuket King Gym','Pangea Resort') and nm <> old then raise exception '% is built in, so its name stays. Add a new business instead.', old; end if;
  select string_agg(x, ', ') into missing from unnest(private.acc_locked(coalesce(old, nm))) x where not x = any(deps);
  if missing is not null then deps := deps || private.acc_locked(coalesce(old, nm)); end if;
  if (old is null or old <> nm) and nm = any(private.acc_businesses()) then raise exception 'There is already a business called %.', nm; end if;
  -- keep the order the owner typed (built in departments added at the end if they were missing)
  for b in select x from jsonb_array_elements(s->'businesses') x loop
    if b->>'name' = coalesce(old, nm) then
      found_it := true;
      lst := lst || jsonb_build_array(jsonb_build_object('name', nm, 'depts', (select jsonb_agg(d order by o) from (select d, min(o) o from unnest(deps) with ordinality u(d, o) group by d) q)));
    else lst := lst || jsonb_build_array(b); end if;
  end loop;
  if not found_it then
    if old is not null and old not in ('Phuket King Gym','Pangea Resort') then raise exception 'Business not found.'; end if;
    lst := lst || jsonb_build_array(jsonb_build_object('name', nm, 'depts', coalesce((select jsonb_agg(d order by o) from (select d, min(o) o from unnest(deps) with ordinality u(d, o) group by d) q), '[]'::jsonb)));
  end if;
  update public.app_settings set value = jsonb_build_object('businesses', lst)::text where key = 'acc_structure';
  -- a new name: move everything already recorded under the old one
  if old is not null and old <> nm then
    update public.expense_receipts set business = nm where business = old;
    update public.acc_entries set business = nm where business = old;
    update public.acc_entries set to_business = nm where to_business = old;
    update public.acc_recurring set business = nm where business = old;
    update public.acc_recurring set split = (select jsonb_agg(case when e->>'business' = old then jsonb_set(e, '{business}', to_jsonb(nm)) else e end) from jsonb_array_elements(split) e)
      where jsonb_typeof(split) = 'array' and split::text like '%' || old || '%';
    update public.invoices set business = nm where business = old;
    update public.places set business = nm where business = old;
    update public.payments set fee_business = nm where fee_business = old;
    update public.packages set acc_business = nm where acc_business = old;
    update public.shop_categories set acc_business = nm where acc_business = old;
    update public.shop_locations set acc_business = nm where acc_business = old;
  end if;
  return jsonb_build_object('ok', true, 'kept', missing);
end $$;
revoke all on function public.acc_business_save(jsonb) from public, anon;
grant execute on function public.acc_business_save(jsonb) to authenticated;

-- remove a business that has nothing recorded
create or replace function public.acc_business_remove(p_name text) returns jsonb language plpgsql security definer set search_path to '' as $$
declare s jsonb := private.acc_struct();
begin
  if not private.can('money') or coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin with money access can change businesses.'; end if;
  if p_name in ('Phuket King Gym','Pangea Resort') then raise exception '% is built in and stays.', p_name; end if;
  if exists (select 1 from public.expense_receipts where business = p_name) or exists (select 1 from public.acc_entries where p_name in (business, to_business))
     or exists (select 1 from public.acc_recurring where business = p_name or split::text like '%"' || p_name || '"%') or exists (select 1 from public.invoices where business = p_name)
     or exists (select 1 from public.payments where fee_business = p_name) then
    raise exception '% has money recorded, so it stays to keep the accounts right. You can rename it.', p_name; end if;
  update public.packages set acc_business = null, acc_department = null where acc_business = p_name;
  update public.shop_categories set acc_business = null, acc_department = null where acc_business = p_name;
  update public.shop_locations set acc_business = null, acc_department = null where acc_business = p_name;
  update public.places set business = 'Pangea Resort' where business = p_name;
  update public.app_settings set value = jsonb_build_object('businesses', coalesce((select jsonb_agg(b) from jsonb_array_elements(s->'businesses') b where b->>'name' <> p_name), '[]'::jsonb))::text where key = 'acc_structure';
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.acc_business_remove(text) from public, anon;
grant execute on function public.acc_business_remove(text) to authenticated;

-- send a package, shop category or till to a business and department (empty = automatic)
create or replace function public.acc_link_save(p_kind text, p_id uuid, p_business text, p_department text) returns jsonb language plpgsql security definer set search_path to '' as $$
declare b text := nullif(btrim(coalesce(p_business,'')),''); d text := nullif(left(btrim(coalesce(p_department,'')),60),'');
begin
  if not private.can('money') or coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin with money access can change this.'; end if;
  if b is not null and not b = any(private.acc_businesses()) then raise exception 'Choose a business.'; end if;
  if b is not null and d is null then raise exception 'Choose the department.'; end if;
  if b is null then d := null; end if;
  if p_kind = 'package' then update public.packages set acc_business = b, acc_department = d where id = p_id;
  elsif p_kind = 'category' then update public.shop_categories set acc_business = b, acc_department = d where id = p_id;
  elsif p_kind = 'till' then update public.shop_locations set acc_business = b, acc_department = d where id = p_id;
  else raise exception 'Unknown kind.'; end if;
  if not found then raise exception 'Not found.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.acc_link_save(text, uuid, text, text) from public, anon;
grant execute on function public.acc_link_save(text, uuid, text, text) to authenticated;

-- the existing checks accept every business on the list
do $$ declare f text; s text;
begin
  foreach f in array array['public.acc_entry_save(jsonb)','public.acc_recurring_save(jsonb)','public.receipt_category(uuid,text,text,text)','public.place_save(jsonb)'] loop
    s := pg_get_functiondef(f::regprocedure);
    if s like '%in (''Phuket King Gym'',''Pangea Resort'')%' then
      s := replace(s, 'not in (''Phuket King Gym'',''Pangea Resort'')', '<> all(private.acc_businesses())');
      s := replace(s, 'in (''Phuket King Gym'',''Pangea Resort'')', '= any(private.acc_businesses())');
      execute s;
    end if;
  end loop;
end $$;

-- receipts: the form can say the business (a department of an added business)
do $$ declare s text;
begin
  s := pg_get_functiondef('public.receipt_add(jsonb)'::regprocedure);
  if s not like '%acc_businesses%' then
    s := replace(s, 'private.receipt_business(dept)', 'case when nullif(p->>''business'','''') = any(private.acc_businesses()) then p->>''business'' else private.receipt_business(dept) end');
    if s not like '%acc_businesses%' then raise exception 'receipt_add patch did not apply'; end if;
    execute s;
  end if;
end $$;

-- sales follow the package, shop category or till when one is set
do $$ declare s text;
begin
  s := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  if s not like '%acc_business%' then
    s := replace(s, 'coalesce(p.fee_business, case when k.id is not null', 'coalesce(p.fee_business, ov.b, case when k.id is not null');
    s := replace(s, 'case when p.is_fee then coalesce(p.fee_dept, ''Card fees'') when p.stay_id is not null', 'case when p.is_fee then coalesce(p.fee_dept, ''Card fees'') when ov.d is not null then ov.d when p.stay_id is not null');
    s := replace(s, 'left join public.privates pv on pv.id = p.private_id', 'left join public.privates pv on pv.id = p.private_id
    left join lateral (select pg.acc_business b, pg.acc_department d from public.packages pg where pg.id = k.package_id and pg.acc_business is not null) ov on true');
    s := replace(s, 'case when lower(coalesce(l.name,'''')) like ''%cafe%'' and lower(coalesce(c.name,'''')) <> ''spa'' then ''Pangea Resort'' else ''Phuket King Gym'' end',
      'coalesce(c.acc_business, l.acc_business, case when lower(coalesce(l.name,'''')) like ''%cafe%'' and lower(coalesce(c.name,'''')) <> ''spa'' then ''Pangea Resort'' else ''Phuket King Gym'' end)');
    s := replace(s, 'case when lower(coalesce(c.name,'''')) = ''spa'' then ''Spa'' when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Cafe'' else ''Gym shop'' end',
      'coalesce(case when c.acc_business is not null then c.acc_department end, case when l.acc_business is not null then l.acc_department end, case when lower(coalesce(c.name,'''')) = ''spa'' then ''Spa'' when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Cafe'' else ''Gym shop'' end)');
    s := replace(s, 'case when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Resort'' else ''Phuket King Gym'' end',
      'coalesce(l.acc_business, case when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Resort'' else ''Phuket King Gym'' end)');
    s := replace(s, 'case when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Cafe'' else ''Gym shop'' end',
      'coalesce(l.acc_department, case when lower(coalesce(l.name,'''')) like ''%cafe%'' then ''Pangea Cafe'' else ''Gym shop'' end)');
    if (length(s) - length(replace(s, 'acc_business', ''))) / length('acc_business') < 7 then raise exception 'acc_lines patch did not fully apply'; end if;
    execute s;
  end if;
end $$;
