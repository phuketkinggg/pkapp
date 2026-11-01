-- App sign-ups that are not customers yet (feature: app_signups). Someone who signs up in the app becomes a customer once they confirm
-- their email and add their name. Until then the front desk sees them on Customers, "Signed up in the app, not finished", and can
-- finish it for them: one tap makes the customer (name typed by the desk), links the login and confirms the email.
create or replace function public.app_signups_pending() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin','front_desk','resort') then return '[]'::jsonb; end if;
  if not private.feature('app_signups', true) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'at', u.created_at, 'confirmed', u.email_confirmed_at is not null) order by u.created_at desc)
    from auth.users u
    where u.created_at > now() - interval '60 days' and u.email is not null and u.deleted_at is null
      and not exists (select 1 from public.customers c where c.user_id = u.id or lower(c.email) = lower(u.email))
      and not exists (select 1 from public.staff s where s.user_id = u.id or lower(s.email) = lower(u.email))), '[]'::jsonb);
end $f$;

create or replace function public.app_signup_finish(p_user uuid, p_name text, p_phone text default null) returns uuid language plpgsql security definer set search_path to '' as $f$
declare u auth.users; cid uuid; n text := nullif(left(btrim(coalesce(p_name,'')), 80), '');
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin','front_desk','resort') then raise exception 'Only the front desk can do this.'; end if;
  if n is null or length(n) < 2 then raise exception 'Type their name.'; end if;
  select * into u from auth.users where id = p_user;
  if u.id is null then raise exception 'That sign-up was not found.'; end if;
  if exists (select 1 from public.staff s where s.user_id = u.id) then raise exception 'That login belongs to a staff member.'; end if;
  select id into cid from public.customers where user_id = u.id or lower(email) = lower(u.email) limit 1;
  if cid is null then
    insert into public.customers (name, email, phone, user_id, tier, price_group) values (n, lower(u.email), nullif(btrim(coalesce(p_phone,'')),''), u.id, 'train', 'standard') returning id into cid;
  else
    update public.customers set user_id = u.id where id = cid and user_id is null;
  end if;
  update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = u.id;
  return cid;
end $f$;

revoke all on function public.app_signups_pending() from public, anon;
revoke all on function public.app_signup_finish(uuid, text, text) from public, anon;
grant execute on function public.app_signups_pending() to authenticated;
grant execute on function public.app_signup_finish(uuid, text, text) to authenticated;
notify pgrst, 'reload schema';
