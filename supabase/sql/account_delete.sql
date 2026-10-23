-- Members can delete their account in the app (needed for the App Store and Google Play).
-- Their login is removed and their personal details and coaching data are wiped. What the business must keep by law
-- (purchases, payments, invoices, check ins, privates, stays) stays, under the name "Deleted member" with no contact details.
-- Staff logins cannot delete themselves this way: the owner removes staff in Staff.
create or replace function public.customer_delete_me(p_confirm text) returns void language plpgsql security definer set search_path to '' as $$
declare uid uuid := auth.uid(); cid uuid; nm text; t text;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  if upper(btrim(coalesce(p_confirm,''))) <> 'DELETE' then raise exception 'Type DELETE to confirm.'; end if;
  if exists (select 1 from public.staff where user_id = uid) then raise exception 'This is a staff login. Ask the owner to remove it in Staff.'; end if;
  select id, name into cid, nm from public.customers where user_id = uid order by created_at limit 1;
  if cid is not null then
    -- personal and coaching data
    foreach t in array array['customer_intake','prearrival','coach_clients','coach_goals','course_progress','exercise_logs','food_logs','form_checks',
                             'group_members','habits','health_marks','programs','weights','chat_members','pangea_service'] loop
      if to_regclass('public.' || t) is not null then execute format('delete from public.%I where customer_id = $1', t) using cid; end if;
    end loop;
    delete from public.chats where customer_id = cid;
    -- records the business keeps, without contact details
    update public.web_pkg_orders set name = 'Deleted member', email = 'deleted@invalid.invalid', phone = null, note = null where customer_id = cid;
    update public.customers set name = 'Deleted member', email = null, phone = null, notes = null, tags = '{}', marketing_ok = false,
      country = null, user_id = null, unsubscribed_at = coalesce(unsubscribed_at, now()) where id = cid;
    insert into public.notices (kind, customer_id, ref_id, title, detail)
    values ('signup', cid, cid, 'Account deleted: ' || coalesce(nm, 'a member'),
      'They deleted their account in the app. Their login, contact details and coaching data are gone. Past purchases, payments and check ins stay under "Deleted member".');
  end if;
  delete from auth.users where id = uid;
end $$;
revoke all on function public.customer_delete_me(text) from public, anon;
grant execute on function public.customer_delete_me(text) to authenticated;
