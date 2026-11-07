-- Add-ons with privates on the website (feature private_addons): the business picks which items people can add when they buy a private
-- (water, hand wraps, lunch, recovery and anything else made as a package), as many as they like, each with how many.
-- The list is a setting (app_settings private_addons: {"items":[package ids]}); not set: the recovery (spa) packages, as before.
-- Each add-on is checked and priced here, and becomes its own purchase when the order is paid (web_pkg_orders.extras).

-- the items on offer, in the order the business chose
create or replace function private.private_addon_ids() returns uuid[]
language plpgsql stable security definer set search_path to '' as $$
declare v jsonb; ids uuid[];
begin
  if not private.feature('private_addons', true) then return '{}'::uuid[]; end if;
  begin v := (select value::jsonb from public.app_settings where key = 'private_addons'); exception when others then v := null; end;
  if jsonb_typeof(v->'items') = 'array' then
    select array_agg(k.id order by x.n) into ids from jsonb_array_elements_text(v->'items') with ordinality x(id, n)
      join public.packages k on k.id::text = x.id and k.active and coalesce(k.price_thb, 0) >= 1 and coalesce(k.audience, 'all') = 'all';
    return coalesce(ids, '{}'::uuid[]);
  end if;
  select array_agg(id order by price_thb) into ids from public.packages where active and coalesce(price_thb, 0) >= 1 and coalesce(audience, 'all') = 'all' and coalesce(covers, '{}') = '{Spa}';
  return coalesce(ids, '{}'::uuid[]);
end $$;

-- for the website: the add-ons, with whether a number can be chosen (single items and single visits)
create or replace function public.private_addons() returns jsonb
language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'price', k.price_thb, 'note', nullif(btrim(coalesce(k.notes, '')), ''),
      'qty', coalesce(k.visit_limit, 0) = 1 or coalesce(k.covers, '{}') = '{}', 'spa', coalesce(k.covers, '{}') = '{Spa}') order by x.n), '[]'::jsonb)
  from unnest(private.private_addon_ids()) with ordinality x(id, n) join public.packages k on k.id = x.id
$$;

-- checks the add-ons in an order: [{package_id, qty}] against the list, priced from the database
create or replace function private.web_addons(p jsonb) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare ids uuid[] := private.private_addon_ids(); e jsonb; k public.packages; q int; out jsonb := '[]'::jsonb; seen uuid[] := '{}';
begin
  if p is null or jsonb_typeof(p) <> 'array' then return null; end if;
  if jsonb_array_length(p) > 12 then raise exception 'Choose up to 12 add-ons.'; end if;
  for e in select * from jsonb_array_elements(p) loop
    begin select * into k from public.packages where id = (e->>'package_id')::uuid; exception when others then raise exception 'Choose the add-ons again.'; end;
    if k.id is null or not (k.id = any(ids)) then raise exception 'That add-on is not available online any more. Choose again, or WhatsApp us.'; end if;
    if k.id = any(seen) then continue; end if; seen := seen || k.id;
    q := coalesce(nullif(e->>'qty','')::int, 1);
    if not (coalesce(k.visit_limit, 0) = 1 or coalesce(k.covers, '{}') = '{}') then q := 1; end if;
    if q < 1 or q > 20 then raise exception 'Choose between 1 and 20 of each add-on.'; end if;
    out := out || jsonb_build_object('package_id', k.id, 'name', k.name, 'qty', q, 'price', k.price_thb * q,
      'label', regexp_replace(k.name, '^Spa Access,\s*', 'Recovery, ') || case when q > 1 then ' x ' || q else '' end);
  end loop;
  return nullif(out, '[]'::jsonb);
end $$;

revoke all on function private.private_addon_ids(), private.web_addons(jsonb) from public, anon, authenticated;
grant execute on function public.private_addons() to anon, authenticated;

-- the order: add-ons go on the total, the order name and its extras. Patch: checks it applied, skips cleanly where web_pkg_order is older.
do $patch$
declare s text; n text;
begin
  if to_regprocedure('public.web_pkg_order(jsonb)') is null then raise notice 'private_addons: no web_pkg_order here, skipped'; return; end if;
  s := pg_get_functiondef('public.web_pkg_order(jsonb)'::regprocedure);
  if s like '%web_addons%' then return; end if;
  n := replace(s, 'ex jsonb; tot int;', 'ex jsonb; tot int; ad jsonb; adl text;');
  n := replace(n, $a$  tot := tot + coalesce((co->>'price')::int, 0);$a$,
$a$  tot := tot + coalesce((co->>'price')::int, 0);
  -- add-ons with privates (water, hand wraps, lunch, recovery and more), chosen by the business
  ad := private.web_addons(p->'addons');
  if ad is not null and not ('Privates' = any (coalesce(k.covers,'{}'))) then raise exception 'Add-ons can be added to privates here.'; end if;
  tot := tot + coalesce((select sum((x->>'price')::int) from jsonb_array_elements(ad) x), 0);
  adl := (select string_agg(' + ' || (x->>'label'), '') from jsonb_array_elements(ad) x);$a$);
  n := replace(n, $a$coalesce(' + ' || (co->>'label'), ''), tot, k.price_thb,$a$, $a$coalesce(' + ' || (co->>'label'), '') || coalesce(adl, ''), tot, k.price_thb,$a$);
  n := replace(n, $a$|| coalesce(jsonb_build_array(co), '[]'::jsonb), '[]'::jsonb),$a$, $a$|| coalesce(jsonb_build_array(co), '[]'::jsonb) || coalesce(ad, '[]'::jsonb), '[]'::jsonb),$a$);
  n := replace(n, $a$'what', k.name || coalesce(' + ' || (ex->>'label'), '') || coalesce(' + ' || (co->>'label'), ''),$a$, $a$'what', k.name || coalesce(' + ' || (ex->>'label'), '') || coalesce(' + ' || (co->>'label'), '') || coalesce(adl, ''),$a$);
  if (length(n) - length(replace(n, 'adl', ''))) / 3 < 4 or n not like '%coalesce(ad, %' then raise notice 'private_addons: web_pkg_order is a different version here, skipped'; return; end if;
  execute n;
end $patch$;
