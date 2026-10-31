-- Staff delete a customer (Customers, open one, Edit, Delete). A customer with nothing recorded is removed completely.
-- A customer with purchases, payments, check ins, privates or stays is wiped like "Delete my account": their login, contact details
-- and coaching data go, and what the business must keep stays under "Deleted customer" with no contact details.
create or replace function public.customer_remove(p_id uuid) returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.customers; t text;
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin') then raise exception 'Only a manager can delete customers.'; end if;
  select * into c from public.customers where id = p_id;
  if c.id is null then raise exception 'Customer not found.'; end if;
  if exists (select 1 from public.staff where user_id = c.user_id and c.user_id is not null) then raise exception 'This customer is also a staff login. Remove them in Staff first.'; end if;
  begin
    delete from public.customers where id = p_id;
    if c.user_id is not null then delete from auth.users where id = c.user_id; end if;
    return jsonb_build_object('ok', true, 'kept', false);
  exception when foreign_key_violation then null;
  end;
  foreach t in array array['customer_intake','prearrival','coach_clients','coach_goals','course_progress','exercise_logs','food_logs','form_checks',
                           'group_members','habits','health_marks','programs','weights','chat_members','pangea_service'] loop
    if to_regclass('public.' || t) is not null then execute format('delete from public.%I where customer_id = $1', t) using p_id; end if;
  end loop;
  if to_regclass('public.chats') is not null then delete from public.chats where customer_id = p_id; end if;
  if to_regclass('public.web_pkg_orders') is not null then
    update public.web_pkg_orders set name = 'Deleted customer', email = 'deleted@invalid.invalid', phone = null, note = null where customer_id = p_id; end if;
  update public.customers set name = 'Deleted customer', email = null, phone = null, notes = null, tags = '{}', marketing_ok = false,
    country = null, user_id = null, unsubscribed_at = coalesce(unsubscribed_at, now()) where id = p_id;
  if c.user_id is not null then delete from auth.users where id = c.user_id; end if;
  return jsonb_build_object('ok', true, 'kept', true);
end $$;
revoke all on function public.customer_remove(uuid) from public, anon;
grant execute on function public.customer_remove(uuid) to authenticated;
