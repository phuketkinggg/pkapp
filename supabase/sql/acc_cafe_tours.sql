-- Accounts: the cafe and tours can each be their own business.
-- app_settings acc_names gets two optional keys:
--   cafe_business  the business cafe sales go to (meal plans, cafe extras on room bookings, the cafe till). Empty: the stay business, as before.
--   tours_business the business tour sales go to (room booking extras or packages sorted as tours). Empty: the main business.
-- A room booking extra counts as cafe or tours by its group in Settings, Rooms (extras with cat cafe or tours), so a protein shake
-- added to a stay is cafe income even though it is not a meal.
-- Built in businesses can now be renamed (everything recorded moves with the name), and the built in names are no longer fixed in code.

create or replace function private.biz_cafe() returns text language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim((select case when value ~ '^\s*\{' then value::jsonb->>'cafe_business' end from public.app_settings where key = 'acc_names')), ''), private.biz_stay())
$$;
create or replace function private.biz_tours() returns text language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim((select case when value ~ '^\s*\{' then value::jsonb->>'tours_business' end from public.app_settings where key = 'acc_names')), ''), private.biz_main())
$$;
-- cafe, tours, spa, gym or other for something bought: its covers first, then the group of the room booking extra it came from
create or replace function private.purchase_zone(c text[], n text) returns text language sql stable security definer set search_path to '' as $$
  select case when private.zone_of_covers(c) = 'cafe' then 'cafe'
    else coalesce((select e->>'cat' from jsonb_array_elements(coalesce((select case when value ~ '^\s*\{' then value::jsonb->'extras' end from public.app_settings where key = 'room_rates'), '[]'::jsonb)) e
                   where e->>'cat' in ('cafe','tours') and coalesce(e->>'name','') <> '' and coalesce(n,'') ilike (e->>'name') || '%' limit 1), private.zone_of_covers(c)) end
$$;
revoke all on function private.biz_cafe() from public, anon, authenticated;
revoke all on function private.biz_tours() from public, anon, authenticated;
revoke all on function private.purchase_zone(text[], text) from public, anon, authenticated;

create or replace function public.acc_names() returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('main', private.biz_main(), 'stay', private.biz_stay(), 'cafe', private.dept_cafe(), 'cafe_business', private.biz_cafe(), 'tours_business', private.biz_tours())
$$;
revoke all on function public.acc_names() from public, anon;
grant execute on function public.acc_names() to authenticated;

-- departments that fill by themselves from sales
create or replace function private.acc_locked(p_b text) returns text[] language sql stable set search_path to '' as $$
  select array(select distinct x from unnest(
      case when p_b = private.biz_main() then array['Gym training','Privates','Spa','Visa and DTV','Gym shop'] else array[]::text[] end
   || case when p_b = private.biz_stay() then array['Rooms'] else array[]::text[] end
   || case when p_b = private.biz_cafe() then array[private.dept_cafe()] else array[]::text[] end
   || case when p_b = private.biz_tours() and private.biz_tours() <> private.biz_main() then array['Tours'] else array[]::text[] end) x)
$$;

-- acc_lines: cafe sales to the cafe business, tours to the tours business (patched in place; checks it applied)
do $p$
declare d text; n text; c int;
begin
  if to_regprocedure('private.acc_lines(date,date)') is null then raise notice 'no acc_lines, skipped'; return; end if;
  d := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  if position('private.biz_cafe()' in d) > 0 then raise notice 'acc_lines already patched'; return; end if;
  n := replace(d, 'private.zone_of_covers(k.covers)=''cafe''', 'private.purchase_zone(k.covers, k.package_name)=''cafe''');
  c := (length(n) - length(replace(n, 'purchase_zone(k.covers, k.package_name)=''cafe''', ''))) / length('purchase_zone(k.covers, k.package_name)=''cafe''');
  if c < 2 then raise notice 'acc_lines is an older version (% cafe spots), skipped', c; return; end if;
  n := replace(n, '=''cafe'' then private.biz_stay()', '=''cafe'' then private.biz_cafe() when private.purchase_zone(k.covers, k.package_name)=''tours'' then private.biz_tours()');
  n := replace(n, '=''cafe'' then private.dept_cafe()', '=''cafe'' then private.dept_cafe() when private.purchase_zone(k.covers, k.package_name)=''tours'' then ''Tours''');
  n := replace(n, '<> ''spa'' then private.biz_stay()', '<> ''spa'' then private.biz_cafe()');
  n := replace(n, 'like ''%cafe%'' then private.biz_stay() else', 'like ''%cafe%'' then private.biz_cafe() else');
  execute n;
  if position('private.biz_cafe()' in pg_get_functiondef('private.acc_lines(date,date)'::regprocedure)) = 0 then raise exception 'acc_lines patch did not apply'; end if;
end $p$;

-- the business list: built in names come from acc_names, not code
create or replace function public.acc_structure() returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare bl text[] := array(select distinct x from unnest(array[private.biz_main(), private.biz_stay(), private.biz_cafe(), private.biz_tours()]) x);
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  return private.acc_struct() || jsonb_build_object('builtin', to_jsonb(bl),
    'locked', (select jsonb_object_agg(x, to_jsonb(private.acc_locked(x))) from unnest(bl) x),
    'links', case when private.can('money') and coalesce(private.staff_role(),'') = 'manager' then jsonb_build_object(
      'packages', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'b',acc_business,'d',acc_department) order by name) from public.packages where active), '[]'::jsonb),
      'categories', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'b',acc_business,'d',acc_department) order by sort, name) from public.shop_categories where active), '[]'::jsonb),
      'tills', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'b',acc_business,'d',acc_department) order by sort, name) from public.shop_locations where active), '[]'::jsonb)) end);
end $$;
revoke all on function public.acc_structure() from public, anon;
grant execute on function public.acc_structure() to authenticated;

-- move everything recorded under one business name to another
create or replace function private.acc_move_business(old text, nm text) returns void language plpgsql security definer set search_path to '' as $$
begin
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
end $$;
revoke all on function private.acc_move_business(text, text) from public, anon, authenticated;

-- add or change one business: {old, name, depts:[...]}. Renaming a built in business renames it in acc_names too.
create or replace function public.acc_business_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
declare s jsonb := private.acc_struct(); old text := nullif(btrim(coalesce(p->>'old','')),''); nm text := btrim(coalesce(p->>'name',''));
  deps text[]; lst jsonb := '[]'::jsonb; b jsonb; found_it boolean := false; missing text; names jsonb; k text;
  builtin text[] := array[private.biz_main(), private.biz_stay(), private.biz_cafe(), private.biz_tours()];
begin
  if not private.can('money') or coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin with money access can change businesses.'; end if;
  if nm = '' then raise exception 'Give the business a name.'; end if;
  if length(nm) > 60 then raise exception 'Keep the name under 60 letters.'; end if;
  select array_agg(distinct d) into deps from (select left(btrim(x),60) d from jsonb_array_elements_text(coalesce(p->'depts','[]'::jsonb)) x) q where d <> '';
  deps := coalesce(deps, array[]::text[]);
  select string_agg(x, ', ') into missing from unnest(private.acc_locked(coalesce(old, nm))) x where not x = any(deps);
  if missing is not null then deps := deps || private.acc_locked(coalesce(old, nm)); end if;
  if (old is null or old <> nm) and nm = any(private.acc_businesses()) then raise exception 'There is already a business called %.', nm; end if;
  for b in select x from jsonb_array_elements(s->'businesses') x loop
    if b->>'name' = coalesce(old, nm) then
      found_it := true;
      lst := lst || jsonb_build_array(jsonb_build_object('name', nm, 'depts', (select jsonb_agg(d order by o) from (select d, min(o) o from unnest(deps) with ordinality u(d, o) group by d) q)));
    else lst := lst || jsonb_build_array(b); end if;
  end loop;
  if not found_it then
    if old is not null and not old = any(builtin) then raise exception 'Business not found.'; end if;
    lst := lst || jsonb_build_array(jsonb_build_object('name', nm, 'depts', coalesce((select jsonb_agg(d order by o) from (select d, min(o) o from unnest(deps) with ordinality u(d, o) group by d) q), '[]'::jsonb)));
  end if;
  update public.app_settings set value = jsonb_build_object('businesses', lst)::text where key = 'acc_structure';
  if old is not null and old <> nm then
    perform private.acc_move_business(old, nm);
    if old = any(builtin) then
      select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'acc_names'), '{}'::jsonb) into names;
      if old = private.biz_main() then names := names || jsonb_build_object('main', nm); end if;
      if old = private.biz_stay() then names := names || jsonb_build_object('stay', nm); end if;
      foreach k in array array['cafe_business','tours_business'] loop if names->>k = old then names := names || jsonb_build_object(k, nm); end if; end loop;
      insert into public.app_settings(key, value) values ('acc_names', names::text) on conflict (key) do update set value = excluded.value;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'kept', missing);
end $$;
revoke all on function public.acc_business_save(jsonb) from public, anon;
grant execute on function public.acc_business_save(jsonb) to authenticated;

-- which business is the cafe and which sells tours (Accounts, Businesses and departments)
create or replace function public.acc_roles_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
declare names jsonb; k text; v text;
begin
  if not private.can('money') or coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin with money access can change businesses.'; end if;
  select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'acc_names'), '{}'::jsonb) into names;
  foreach k in array array['cafe_business','tours_business'] loop
    if p ? k then v := nullif(btrim(coalesce(p->>k,'')),'');
      if v is not null and not v = any(private.acc_businesses()) then raise exception 'There is no business called %.', v; end if;
      names := case when v is null then names - k else names || jsonb_build_object(k, v) end; end if;
  end loop;
  insert into public.app_settings(key, value) values ('acc_names', names::text) on conflict (key) do update set value = excluded.value;
  return public.acc_names();
end $$;
revoke all on function public.acc_roles_save(jsonb) from public, anon;
grant execute on function public.acc_roles_save(jsonb) to authenticated;

-- removing a business: built ins stay, places go to the stay business
do $p$
declare d text;
begin
  if to_regprocedure('public.acc_business_remove(text)') is null then return; end if;
  d := pg_get_functiondef('public.acc_business_remove(text)'::regprocedure);
  if position('''Phuket King Gym'',''Pangea Resort''' in d) = 0 then raise notice 'acc_business_remove already patched'; return; end if;
  d := replace(d, 'if p_name in (''Phuket King Gym'',''Pangea Resort'') then', 'if p_name in (private.biz_main(), private.biz_stay(), private.biz_cafe(), private.biz_tours()) then');
  d := replace(d, 'set business = ''Pangea Resort'' where business = p_name', 'set business = private.biz_stay() where business = p_name');
  execute d;
end $p$;
