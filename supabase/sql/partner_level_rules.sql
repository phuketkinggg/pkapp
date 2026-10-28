-- Partner levels with a share per product (Affiliates, What each level earns on): approving someone copies the level's shares to them.

-- approve (makes them an affiliate with that level's share) or decline
create or replace function public.partner_app_decide(p_id uuid, p_ok boolean, p_level text default null, p_note text default null) returns uuid language plpgsql security definer set search_path to '' as $f$
declare a public.partner_applications; lv jsonb; aff uuid; code text;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can decide applications.'; end if;
  select * into a from public.partner_applications where id = p_id for update;
  if a.id is null then raise exception 'That application was not found.'; end if;
  if a.status <> 'new' then raise exception 'That application was already decided.'; end if;
  if not p_ok then
    update public.partner_applications set status = 'declined', decided_by = private.my_staff_id(), decided_at = now(), note = nullif(left(btrim(coalesce(p_note,'')),400),'') where id = a.id;
    return null;
  end if;
  select x into lv from jsonb_array_elements(private.partner_levels()) x where x->>'id' = coalesce(p_level, a.level) limit 1;
  if lv is null then raise exception 'Choose a level.'; end if;
  select id into aff from public.affiliates where lower(email) = a.email limit 1;
  if aff is null then
    aff := public.affiliate_save(jsonb_build_object('name', a.name, 'email', a.email, 'phone', a.phone, 'pct', lv->>'pct', 'active', true,
      'note', left(concat_ws(E'\n', lv->>'name' || ' partner.', a.links, nullif(p_note,'')), 400)));
  else
    update public.affiliates set pct = (lv->>'pct')::numeric, active = true where id = aff;
  end if;
  update public.affiliates set level = lv->>'id' where id = aff;
  -- the level's share per product (rooms, packages, courses), when it has one
  if jsonb_typeof(lv->'rules') = 'object' then perform public.affiliate_rules_set(aff, lv->'rules'); end if;
  update public.partner_applications set status = 'approved', level = lv->>'id', affiliate_id = aff, decided_by = private.my_staff_id(), decided_at = now(),
    note = nullif(left(btrim(coalesce(p_note,'')),400),'') where id = a.id;
  update public.notices set done_at = now() where kind = 'partner' and ref_id = a.id and done_at is null;
  return aff;
end $f$;

-- the website page: the levels, without the per product lists
create or replace function public.partner_levels_public() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when private.feature('partners', true)
    then coalesce((select jsonb_agg(x - 'rules') from jsonb_array_elements(private.partner_levels()) x), '[]'::jsonb) else '[]'::jsonb end
$f$;

notify pgrst, 'reload schema';
