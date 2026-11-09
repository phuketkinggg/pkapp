-- Add an agency booking by hand or with Ask AI (from a screenshot or a pasted confirmation): the same filing as booking
-- emails (agency_mail_ingest: the customer, a private, or the guest name on a stay, never twice for one reference),
-- plus, for a group class, a class credit for the guest at the agency's net rate, paid by the agency.
-- p: {source, ref, kind (class, private, stay), name, email, phone, people, date, time, minutes, product, notes,
--     net_thb (what the agency pays the business, for all the people), package_id (optional: the package the credit is)}
-- Needs agency_mail.sql. Where it is missing (an older demo) this file skips cleanly.

do $p$
begin
  if to_regprocedure('public.agency_mail_ingest(jsonb,uuid)') is null then raise notice 'no agency_mail_ingest here, skipped'; return; end if;
  execute $f$
create or replace function public.agency_booking_add(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $q$
declare r jsonb; b public.agency_bookings; k public.packages; net int; ppl int := greatest(1, least(100, coalesce(nullif(p->>'people','')::int, 1))); pid uuid; what text;
begin
  if not private.is_desk() then raise exception 'Only the front desk or a manager can add bookings.'; end if;
  begin net := round(nullif(p->>'net_thb','')::numeric)::int; exception when others then net := null; end;
  if net is not null and (net < 0 or net > 1000000) then raise exception 'The net rate looks wrong.'; end if;
  r := public.agency_mail_ingest(p - 'net_thb' - 'package_id', null);
  if not coalesce((r->>'ok')::boolean, false) or r->>'booking' is null then return r; end if;
  select * into b from public.agency_bookings where id = (r->>'booking')::uuid;
  if r->>'what' in ('Already in the app.') or b.status = 'cancelled' then return r; end if;
  what := r->>'what';
  if b.kind = 'private' and b.private_id is not null and net is not null then
    update public.privates set price_thb = net, paid = true, method = 'agent' where id = b.private_id;
    what := what || ' Net ' || net || ' THB, paid by ' || coalesce(b.source_name, 'the agency') || '.';
  elsif b.kind = 'class' and b.customer_id is not null then
    -- the class credit: the package asked for, else the cheapest one class package for adults' group classes
    begin select * into k from public.packages where id = nullif(p->>'package_id','')::uuid; exception when others then k := null; end;
    if k.id is null then
      select * into k from public.packages where active and visit_limit = 1 and coalesce(audience,'all') = 'all' and 'Muay Thai' = any(covers) and not ('Kids' = any(covers))
        and not ('Privates' = any(covers)) order by array_length(covers,1), price_thb limit 1;
    end if;
    if k.id is null then return r || jsonb_build_object('what', what || ' No one class package found, so no class credit was added. Add a package in Packages.'); end if;
    insert into public.purchases(customer_id, package_id, package_name, price_thb, price_group, paid, paid_thb, method, source_id, purchased_on, covers, times, visit_limit, visits_left, starts_on, sold_by)
    values (b.customer_id, k.id, k.name || case when ppl > 1 then ', ' || ppl || ' people' else '' end, coalesce(net, 0), 'standard', true, coalesce(net, 0), 'agent', b.source_id,
      private.bkk_today(), k.covers, k.times, ppl, ppl, b.date, private.my_staff_id())
    returning id into pid;
    update public.agency_bookings set notes = left(concat_ws('. ', notes, ppl || ' class credit' || case when ppl > 1 then 's' else '' end || ' added' || coalesce(', net ' || net || ' THB', '')), 500), updated_at = now() where id = b.id;
    what := what || ' ' || ppl || ' class credit' || case when ppl > 1 then 's' else '' end || ' (' || k.name || ')' || coalesce(', net ' || net || ' THB', '') || ', paid by ' || coalesce(b.source_name, 'the agency') || '.';
  end if;
  return jsonb_build_object('ok', true, 'booking', b.id, 'customer', b.customer_id, 'purchase', pid, 'what', what);
end $q$;
$f$;
  revoke all on function public.agency_booking_add(jsonb) from public, anon;
  grant execute on function public.agency_booking_add(jsonb) to authenticated;
end $p$;

notify pgrst, 'reload schema';
