-- Treatment packs for spa and salon apps: a pack of sessions (for example 10 x 60 minute Thai massage), for the treatments ticked
-- on the package (packages.service_ids; empty means any treatment). The front desk pays an appointment from the pack on the board.
-- Uses the same pack rules as private packs (guard_private): sessions left, expiry, the session price and paid.
-- Needs the spa functions (spa_shops.sql); on a database without them it only adds the column.
alter table public.packages add column if not exists service_ids uuid[];

do $outer$
begin
  if to_regprocedure('private.spa_free_staff(uuid, date, time, uuid, uuid)') is null then
    raise notice 'spa_packs: no spa functions here, skipped'; return;
  end if;

  execute $f$
  create or replace function public.spa_pack_options(p_id uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $$
  declare a public.privates;
  begin
    if coalesce(private.staff_role(),'') not in ('manager','admin','front_desk') then return '[]'::jsonb; end if;
    select * into a from public.privates where id = p_id;
    if a.id is null or a.paid or a.status = 'cancelled' then return '[]'::jsonb; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', pu.id, 'name', pu.package_name, 'expires', pu.expires_on,
        'left', pu.visit_limit - coalesce(pu.used_before,0) - (select count(*) from public.privates x where x.purchase_id = pu.id and x.status <> 'cancelled')) order by pu.expires_on nulls last, pu.created_at)
      from public.purchases pu left join public.packages k on k.id = pu.package_id
      where pu.customer_id = a.customer_id and not coalesce(pu.cancelled,false) and 'Privates' = any(pu.covers) and pu.visit_limit is not null
        and not (coalesce(pu.ordered_in_app,false) and not coalesce(pu.paid,false))
        and (pu.expires_on is null or pu.expires_on >= a.date)
        and (k.service_ids is null or cardinality(k.service_ids) = 0 or a.service_id = any(k.service_ids))
        and pu.visit_limit - coalesce(pu.used_before,0) - (select count(*) from public.privates x where x.purchase_id = pu.id and x.status <> 'cancelled') > 0), '[]'::jsonb);
  end $$;
  $f$;

  execute $f$
  create or replace function public.spa_pay_pack(p_id uuid, p_purchase uuid) returns jsonb language plpgsql security definer set search_path to '' as $$
  begin
    if coalesce(private.staff_role(),'') not in ('manager','admin','front_desk') then raise exception 'Only the front desk takes payment.'; end if;
    if not exists (select 1 from jsonb_array_elements(public.spa_pack_options(p_id)) o where (o->>'id')::uuid = p_purchase) then
      raise exception 'That pack cannot pay for this treatment.'; end if;
    update public.privates set purchase_id = p_purchase, method = 'pack' where id = p_id and not paid and status <> 'cancelled';
    if not found then raise exception 'That booking is already paid or was cancelled.'; end if;
    return jsonb_build_object('ok', true);
  end $$;
  $f$;

  revoke all on function public.spa_pack_options(uuid) from public, anon;
  revoke all on function public.spa_pay_pack(uuid, uuid) from public, anon;
  grant execute on function public.spa_pack_options(uuid) to authenticated;
  grant execute on function public.spa_pay_pack(uuid, uuid) to authenticated;
end $outer$;
