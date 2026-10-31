-- Delete a stay (managers and admins). For stays made by mistake: a stay with money paid is kept (set it to
-- Cancelled instead, so the accounts stay right), and a stay from a booking site or MotoPress is cancelled there.
-- Extras on the stay that are not paid are cancelled, its food plans, cleaning and requests go with it.
create or replace function public.stay_remove(p_id uuid) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare s public.stays;
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin') then raise exception 'Only a manager can delete a stay. Set it to Cancelled instead.'; end if;
  select * into s from public.stays where id = p_id;
  if s.id is null then raise exception 'Stay not found.'; end if;
  if coalesce(s.external_id,'') <> '' then raise exception 'This stay came from a booking site. Cancel it there, or set it to Cancelled here.'; end if;
  if coalesce(s.room_paid_thb,0) > 0 or coalesce(s.settled,false)
     or exists (select 1 from public.payments p where p.stay_id = s.id)
     or exists (select 1 from public.purchases p where (p.for_stay = s.id or p.stay_id = s.id) and not p.cancelled and (p.paid or coalesce(p.paid_thb,0) > 0)) then
    raise exception 'Money was paid on this stay, so it is kept for the accounts. Set it to Cancelled instead.';
  end if;
  update public.purchases set cancelled = true where (for_stay = s.id or stay_id = s.id) and not cancelled and not paid and coalesce(paid_thb,0) = 0;
  delete from public.food_plans where stay_id = s.id;
  delete from public.room_cleanings where stay_id = s.id;
  delete from public.room_requests where stay_id = s.id;
  delete from public.stays where id = s.id;
  return jsonb_build_object('ok', true);
exception when foreign_key_violation then
  raise exception 'This stay is still linked to other records. Set it to Cancelled instead.';
end $f$;
revoke all on function public.stay_remove(uuid) from public, anon;
grant execute on function public.stay_remove(uuid) to authenticated;
notify pgrst, 'reload schema';
