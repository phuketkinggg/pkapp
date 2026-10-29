-- Modifiers for the shop (feature: shop_modifiers), like Loyverse: a modifier is a list of choices with their own price,
-- for example Milk (Oat milk +20, Almond milk +25), Hot or iced (Hot +0, Iced +10) or Extras (Add cheese +30).
-- A modifier can be one to pick (required: they must choose one), and can allow several choices.
-- Put modifiers on products. At the till and in the app the choices are asked when the product is added,
-- the price includes them, and the kitchen and the receipt show them after the name, for example: Latte (Oat milk, Iced).
-- Variants with their own price (Latte, Espresso) stay as products with the same Group (one button on the till).

create table if not exists public.shop_modifiers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  required boolean not null default false,
  multi boolean not null default false,
  options jsonb not null default '[]'::jsonb,
  sort integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.shop_modifiers enable row level security;
revoke all on public.shop_modifiers from anon, authenticated;
alter table public.shop_products add column if not exists modifier_ids uuid[] not null default '{}';
alter table public.shop_order_items add column if not exists mods jsonb;

-- the choices for one product line: checked and priced here, never by the till or the app
create or replace function private.shop_mods(p_product uuid, p_sel jsonb) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare pr public.shop_products; m public.shop_modifiers; o jsonb; sel text[]; n int; extra int := 0; names text[] := '{}'; list jsonb := '[]'::jsonb;
begin
  if not private.feature('shop_modifiers', true) then return jsonb_build_object('label', '', 'extra', 0, 'list', null); end if;
  select * into pr from public.shop_products where id = p_product;
  sel := coalesce((select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(p_sel) = 'array' then p_sel else '[]'::jsonb end) x), '{}');
  for m in select * from public.shop_modifiers where id = any (coalesce(pr.modifier_ids, '{}')) and active order by sort, name loop
    n := 0;
    for o in select * from jsonb_array_elements(m.options) loop
      if (o->>'id') = any (sel) then
        n := n + 1;
        if n > 1 and not m.multi then raise exception 'Choose one % for %.', lower(m.name), pr.name; end if;
        extra := extra + coalesce((o->>'price')::numeric::int, 0);
        names := names || (o->>'name');
        list := list || jsonb_build_object('modifier', m.name, 'name', o->>'name', 'price', coalesce((o->>'price')::numeric::int, 0));
      end if;
    end loop;
    if n = 0 and m.required then raise exception 'Choose % for %.', lower(m.name), pr.name; end if;
  end loop;
  return jsonb_build_object('label', array_to_string(names, ', '), 'extra', extra, 'list', case when jsonb_array_length(list) > 0 then list end);
end $f$;
revoke all on function private.shop_mods(uuid, jsonb) from public, anon, authenticated;

-- manager: add or change a modifier; with "products" (a list of product ids) it also sets exactly which products use it
create or replace function public.shop_modifier_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v_id uuid := nullif(p->>'id','')::uuid; nm text := left(btrim(coalesce(p->>'name','')), 60); opts jsonb := '[]'::jsonb; o jsonb; on_ text; ids uuid[];
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change modifiers.'; end if;
  if nm = '' then raise exception 'Give the modifier a name, for example Milk.'; end if;
  for o in select * from jsonb_array_elements(case when jsonb_typeof(p->'options') = 'array' then p->'options' else '[]'::jsonb end) loop
    on_ := left(btrim(coalesce(o->>'name','')), 60); if on_ = '' then continue; end if;
    if coalesce((o->>'price')::numeric, 0) < -100000 or coalesce((o->>'price')::numeric, 0) > 100000 then raise exception 'Check the price of %.', on_; end if;
    opts := opts || jsonb_build_object('id', coalesce(nullif(o->>'id',''), 'o' || substr(md5(random()::text), 1, 8)), 'name', on_, 'price', round(coalesce((o->>'price')::numeric, 0))::int);
  end loop;
  if jsonb_array_length(opts) = 0 then raise exception 'Add at least one choice, for example Oat milk 20.'; end if;
  if v_id is null then
    insert into public.shop_modifiers (name, required, multi, options, sort) values (nm, coalesce((p->>'required')::boolean, false), coalesce((p->>'multi')::boolean, false), opts,
      coalesce((select max(sort) + 1 from public.shop_modifiers), 0)) returning id into v_id;
  else
    update public.shop_modifiers set name = nm, required = coalesce((p->>'required')::boolean, false), multi = coalesce((p->>'multi')::boolean, false), options = opts,
      sort = coalesce(nullif(p->>'sort','')::numeric::int, sort), active = true where id = v_id;
    if not found then raise exception 'That modifier was not found.'; end if;
  end if;
  if p ? 'products' and jsonb_typeof(p->'products') = 'array' then
    select coalesce(array_agg(x::uuid), '{}') into ids from jsonb_array_elements_text(p->'products') x where x ~ '^[0-9a-f-]{36}$';
    update public.shop_products set modifier_ids = array_remove(modifier_ids, v_id) where v_id = any (modifier_ids) and not (id = any (ids));
    update public.shop_products set modifier_ids = modifier_ids || v_id where id = any (ids) and not (v_id = any (modifier_ids));
  end if;
  return v_id;
end $f$;

create or replace function public.shop_modifier_remove(p_id uuid) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change modifiers.'; end if;
  update public.shop_modifiers set active = false where id = p_id;
  update public.shop_products set modifier_ids = array_remove(modifier_ids, p_id) where p_id = any (modifier_ids);
end $f$;

-- manager: which modifiers one product uses (from the product)
create or replace function public.shop_product_mods(p_product uuid, p_ids uuid[]) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change products.'; end if;
  update public.shop_products set modifier_ids = coalesce((select array_agg(m.id order by m.sort, m.name) from public.shop_modifiers m where m.active and m.id = any (coalesce(p_ids, '{}'))), '{}')
  where id = p_product;
end $f$;

revoke all on function public.shop_modifier_save(jsonb), public.shop_modifier_remove(uuid), public.shop_product_mods(uuid, uuid[]) from public, anon;
grant execute on function public.shop_modifier_save(jsonb), public.shop_modifier_remove(uuid), public.shop_product_mods(uuid, uuid[]) to authenticated;

do $p$
declare s text;
begin
  -- the menu: the modifiers, and which ones each product uses
  if to_regprocedure('public.shop_catalog()') is null then raise notice 'no shop_catalog, skipped';
  else
    s := pg_get_functiondef('public.shop_catalog()'::regprocedure);
    if position('shop_modifiers' in s) > 0 then raise notice 'shop_catalog already patched';
    elsif position('''grp'', p.grp,' in s) = 0 or position('''role'', role,' in s) = 0 then raise notice 'shop_catalog: older version, skipped';
    else
      s := replace(s, '''grp'', p.grp,', '''grp'', p.grp, ''mods'', to_jsonb(p.modifier_ids),');
      s := replace(s, '''role'', role,', '''role'', role, ''modifiers'', (select coalesce(jsonb_agg(jsonb_build_object(''id'', m.id, ''name'', m.name, ''required'', m.required, ''multi'', m.multi, ''options'', m.options, ''sort'', m.sort) order by m.sort, m.name), ''[]''::jsonb) from public.shop_modifiers m where m.active),');
      execute s;
      if position('shop_modifiers' in pg_get_functiondef('public.shop_catalog()'::regprocedure)) = 0 then raise exception 'shop_catalog patch did not apply'; end if;
    end if;
  end if;
  -- the till: the choices are checked, priced and written after the name
  if to_regprocedure('public.shop_sell(jsonb)') is null then raise notice 'no shop_sell, skipped';
  else
    s := pg_get_functiondef('public.shop_sell(jsonb)'::regprocedure);
    if position('shop_mods' in s) > 0 then raise notice 'shop_sell already patched';
    elsif position('mn text; mp numeric;' in s) = 0 or position('insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen) values (o.id, pr.id, pr.name, pr.price_thb, qty, nullif(btrim(it->>''note''),''''), pr.kitchen);' in s) = 0 then
      raise notice 'shop_sell: older version, skipped';
    else
      s := replace(s, 'mn text; mp numeric;', 'mn text; mp numeric; md jsonb;');
      s := replace(s, 'insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen) values (o.id, pr.id, pr.name, pr.price_thb, qty, nullif(btrim(it->>''note''),''''), pr.kitchen);',
        'md := private.shop_mods(pr.id, it->''mods''); pr.price_thb := pr.price_thb + coalesce((md->>''extra'')::int, 0);
      insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen, mods) values (o.id, pr.id, left(pr.name || coalesce('' ('' || nullif(md->>''label'', '''') || '')'', ''''), 200), pr.price_thb, qty, nullif(btrim(it->>''note''),''''), pr.kitchen, md->''list'');');
      execute s;
      if position('shop_mods' in pg_get_functiondef('public.shop_sell(jsonb)'::regprocedure)) = 0 then raise exception 'shop_sell patch did not apply'; end if;
    end if;
  end if;
  -- app orders: the same
  if to_regprocedure('public.shop_app_order(jsonb)') is null then raise notice 'no shop_app_order, skipped';
  else
    s := pg_get_functiondef('public.shop_app_order(jsonb)'::regprocedure);
    if position('shop_mods' in s) > 0 then raise notice 'shop_app_order already patched';
    elsif position('loc uuid := private.shop_app_location();' in s) = 0 or position('insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen) values (o.id, pr.id, pr.name, pr.price_thb, qty, left(nullif(btrim(it->>''note''),''''), 120), pr.kitchen);' in s) = 0 then
      raise notice 'shop_app_order: older version, skipped';
    else
      s := replace(s, 'loc uuid := private.shop_app_location();', 'loc uuid := private.shop_app_location(); md jsonb;');
      s := replace(s, 'insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen) values (o.id, pr.id, pr.name, pr.price_thb, qty, left(nullif(btrim(it->>''note''),''''), 120), pr.kitchen);',
        'md := private.shop_mods(pr.id, it->''mods''); pr.price_thb := pr.price_thb + coalesce((md->>''extra'')::int, 0);
    insert into public.shop_order_items (order_id, product_id, name, price_thb, qty, note, kitchen, mods) values (o.id, pr.id, left(pr.name || coalesce('' ('' || nullif(md->>''label'', '''') || '')'', ''''), 200), pr.price_thb, qty, left(nullif(btrim(it->>''note''),''''), 120), pr.kitchen, md->''list'');');
      execute s;
      if position('shop_mods' in pg_get_functiondef('public.shop_app_order(jsonb)'::regprocedure)) = 0 then raise exception 'shop_app_order patch did not apply'; end if;
    end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
