-- Sharing a room (feature stay_share): someone staying in a room booked under another guest's name can be linked to that stay.
-- Then anything they buy (packages, privates, shop and cafe, their own app orders) can go on that room's bill, like the main guest.
-- stays.guest_ids: the customers linked to the stay besides the one it is booked under.
alter table public.stays add column if not exists guest_ids uuid[] not null default '{}';
create index if not exists stays_guest_ids_idx on public.stays using gin (guest_ids);

-- the team: link or unlink a customer to a stay (their name is added to the names of who is in the room)
create or replace function public.stay_share(p_stay uuid, p_customer uuid, p_on boolean) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare s public.stays; nm text;
begin
  if not private.is_desk() then raise exception 'Only the team can do this.'; end if;
  select * into s from public.stays where id = p_stay;
  if s.id is null then raise exception 'That stay was not found.'; end if;
  if s.customer_id = p_customer then raise exception 'The stay is already under their name.'; end if;
  select name into nm from public.customers where id = p_customer;
  if nm is null then raise exception 'That customer was not found.'; end if;
  if p_on then
    update public.stays set guest_ids = (select array_agg(distinct x) from unnest(guest_ids || p_customer) x),
      guest_names = case when lower(btrim(nm)) in (select lower(btrim(x)) from regexp_split_to_table(coalesce(guest_names, ''), E'\n|,') x) then guest_names
        else btrim(coalesce(nullif(btrim(guest_names), ''), (select c.name from public.customers c where c.id = s.customer_id), '') || E'\n' || btrim(nm)) end
      where id = p_stay;
  else
    update public.stays set guest_ids = array_remove(guest_ids, p_customer) where id = p_stay;
  end if;
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.stay_share(uuid, uuid, boolean) from public, anon;
grant execute on function public.stay_share(uuid, uuid, boolean) to authenticated;

-- Room charges and the guest's own app also find a stay they are linked to, not only one under their name.
-- Each patch checks it applied, and skips cleanly where a database has an older version of the function.
do $p$
declare r record; d text; n text; f oid;
begin
  for r in select * from (values
    ('private', 'charge_purchase_to_room', 's.customer_id = new.customer_id and s.status', '(s.customer_id = new.customer_id or new.customer_id = any(s.guest_ids)) and s.status'),
    ('private', 'private_room_charge', 's.customer_id = new.customer_id and s.status', '(s.customer_id = new.customer_id or new.customer_id = any(s.guest_ids)) and s.status'),
    ('public', 'customer_private_pay', 's.customer_id = c.id and s.status', '(s.customer_id = c.id or c.id = any(s.guest_ids)) and s.status'),
    ('public', 'customer_stay', 's.customer_id = v_customer and s.status', '(s.customer_id = v_customer or v_customer = any(s.guest_ids)) and s.status'),
    ('public', 'customer_stay_as', 's.customer_id = v_customer and s.status', '(s.customer_id = v_customer or v_customer = any(s.guest_ids)) and s.status'),
    ('public', 'shop_app_order', 'where customer_id = me_c and status', 'where (customer_id = me_c or me_c = any(guest_ids)) and status')
  ) v(sch, fn, a, b) loop
    for f in select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = r.sch and p.proname = r.fn loop
      d := pg_get_functiondef(f);
      if position('guest_ids' in d) > 0 then raise notice 'stay_share: %.% already done', r.sch, r.fn; continue; end if;
      if position(r.a in d) = 0 then raise notice 'stay_share: %.% is a different version here, skipped', r.sch, r.fn; continue; end if;
      n := replace(d, r.a, r.b);
      execute n;
      if position('guest_ids' in pg_get_functiondef(f)) = 0 then raise exception 'stay_share: %.% did not patch', r.sch, r.fn; end if;
    end loop;
  end loop;
end $p$;

notify pgrst, 'reload schema';
