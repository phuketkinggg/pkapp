-- Extras on any package (feature package_extras): each package can list other packages people can add when they buy it on the website,
-- for example Women's Muay Thai 200 with Recovery +100. Set on the package (Extras people can add). Checked and priced here,
-- each extra becomes its own purchase when the order is paid (as with the extras on privates).
alter table public.packages add column if not exists extra_ids uuid[] not null default '{}';

-- the extras for one package: its own list, else for privates the business's list of extras with privates
create or replace function private.package_addon_ids(p_pkg uuid) returns uuid[]
language plpgsql stable security definer set search_path to '' as $$
declare k public.packages; ids uuid[];
begin
  select * into k from public.packages where id = p_pkg;
  if k.id is null then return '{}'::uuid[]; end if;
  if private.feature('package_extras', true) and coalesce(array_length(k.extra_ids, 1), 0) > 0 then
    select array_agg(x.id order by x.n) into ids from unnest(k.extra_ids) with ordinality x(id, n)
      join public.packages e on e.id = x.id and e.id <> k.id and e.active and coalesce(e.price_thb, 0) >= 1 and coalesce(e.audience, 'all') = 'all';
    return coalesce(ids, '{}'::uuid[]);
  end if;
  if 'Privates' = any (coalesce(k.covers, '{}')) then return private.private_addon_ids(); end if;
  return '{}'::uuid[];
end $$;

-- for the website: the extras of one package, with whether a number can be chosen
create or replace function public.package_addons(p_package uuid) returns jsonb
language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'price', k.price_thb, 'note', nullif(btrim(coalesce(k.notes, '')), ''),
      'qty', coalesce(k.visit_limit, 0) = 1 or coalesce(k.covers, '{}') = '{}', 'spa', coalesce(k.covers, '{}') = '{Spa}') order by x.n), '[]'::jsonb)
  from unnest(private.package_addon_ids(p_package)) with ordinality x(id, n) join public.packages k on k.id = x.id
$$;

-- checks the extras in an order against that package's list, priced from the database
create or replace function private.web_addons(p jsonb, p_pkg uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare ids uuid[] := private.package_addon_ids(p_pkg); e jsonb; k public.packages; q int; out jsonb := '[]'::jsonb; seen uuid[] := '{}';
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then return null; end if;
  if jsonb_array_length(p) > 12 then raise exception 'Choose up to 12 extras.'; end if;
  for e in select * from jsonb_array_elements(p) loop
    begin select * into k from public.packages where id = (e->>'package_id')::uuid; exception when others then raise exception 'Choose the extras again.'; end;
    if k.id is null or not (k.id = any(ids)) then raise exception 'That extra is not available online any more. Choose again, or WhatsApp us.'; end if;
    if k.id = any(seen) then continue; end if; seen := seen || k.id;
    q := coalesce(nullif(e->>'qty','')::int, 1);
    if not (coalesce(k.visit_limit, 0) = 1 or coalesce(k.covers, '{}') = '{}') then q := 1; end if;
    if q < 1 or q > 20 then raise exception 'Choose between 1 and 20 of each extra.'; end if;
    out := out || jsonb_build_object('package_id', k.id, 'name', k.name, 'qty', q, 'price', k.price_thb * q,
      'label', regexp_replace(k.name, '^Spa Access,\s*', 'Recovery, ') || case when q > 1 then ' x ' || q else '' end);
  end loop;
  return nullif(out, '[]'::jsonb);
end $$;

revoke all on function private.package_addon_ids(uuid), private.web_addons(jsonb, uuid) from public, anon, authenticated;
revoke all on function public.package_addons(uuid) from public;
grant execute on function public.package_addons(uuid) to anon, authenticated;

-- the order: extras checked against the package bought. Patch: checks it applied, skips cleanly where web_pkg_order is older.
do $patch$
declare s text; n text; a text := $a$  ad := private.web_addons(p->'addons');
  if ad is not null and not ('Privates' = any (coalesce(k.covers,'{}'))) then raise exception 'Add-ons can be added to privates here.'; end if;$a$;
begin
  if to_regprocedure('public.web_pkg_order(jsonb)') is null then raise notice 'package_extras: no web_pkg_order here, skipped'; return; end if;
  s := pg_get_functiondef('public.web_pkg_order(jsonb)'::regprocedure);
  if s like '%web_addons(p->''addons'', k.id)%' then return; end if;
  if position(a in s) = 0 then raise notice 'package_extras: web_pkg_order is a different version here, skipped'; return; end if;
  n := replace(s, a, $a$  ad := private.web_addons(p->'addons', k.id);$a$);
  if n not like '%web_addons(p->''addons'', k.id)%' then raise exception 'package_extras: patch did not apply'; end if;
  execute n;
end $patch$;
notify pgrst, 'reload schema';
