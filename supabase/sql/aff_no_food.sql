-- Affiliates earn nothing on food, drinks and small items (water, lunch, hand wraps: packages with no classes, or cafe meal plans)
-- unless the owner allows it (app_settings aff_food = true, set in the app: Affiliates). Rooms already earn on the room price only.
create or replace function private.aff_food_ok() returns boolean
language sql stable security definer set search_path to '' as $$
  select coalesce((select lower(btrim(value, '" ')) = 'true' from public.app_settings where key = 'aff_food'), false)
$$;

create or replace function private.aff_is_food(p_package uuid) returns boolean
language sql stable security definer set search_path to '' as $$
  select coalesce((select coalesce(k.covers, '{}') = '{}' or 'Cafe meal' = any(k.covers) from public.packages k where k.id = p_package), false)
$$;

create or replace function private.aff_pct(a public.affiliates, p_kind text, p_ref uuid)
returns numeric language sql stable set search_path to '' as $$
  select case
    when p_kind = 'package' and private.aff_is_food(p_ref) and not private.aff_food_ok() then null
    when a.rules is null then a.pct
    when p_kind = 'stay' then nullif(a.rules->>'stays','')::numeric
    when p_kind = 'package' then coalesce(nullif(a.rules->'packages'->>p_ref::text,'')::numeric, nullif(a.rules->>'other','')::numeric)
    when p_kind = 'course' then coalesce(nullif(a.rules->'courses'->>p_ref::text,'')::numeric, nullif(a.rules->>'other','')::numeric) end
$$;

-- the owner allows or stops commission on food and small items
create or replace function public.aff_food_set(p_on boolean) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only the owner can change this.'; end if;
  insert into public.app_settings (key, value) values ('aff_food', case when p_on then 'true' else 'false' end)
    on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

revoke all on function private.aff_food_ok(), private.aff_is_food(uuid) from public, anon;
grant execute on function private.aff_food_ok(), private.aff_is_food(uuid) to authenticated;
revoke all on function public.aff_food_set(boolean) from public, anon;
grant execute on function public.aff_food_set(boolean) to authenticated;
