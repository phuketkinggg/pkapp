-- Free gyms share one login system. When someone confirms their email (sign up, or "Email me a link"), link them to
-- every gym where staff or a customer was added with that email, the same as the live app's link_user trigger does.
-- Without this, staff a gym added by email could never get into its back office.
create or replace function mf.link_user_all() returns trigger language plpgsql security definer set search_path to '' as $$
declare g record;
begin
  if new.email is null or new.email_confirmed_at is null then return new; end if;
  if tg_op = 'UPDATE' and old.email_confirmed_at is not null and old.email is not distinct from new.email then return new; end if;
  for g in select schema_pub from mf.gyms where status = 'ready' loop
    begin
      execute format('update %I.staff set user_id = $1 where user_id is null and lower(email) = lower($2)', g.schema_pub) using new.id, new.email;
      execute format('update %1$I.customers set user_id = $1 where id = (select c.id from %1$I.customers c where c.user_id is null and lower(c.email) = lower($2) order by c.created_at limit 1)
        and not exists (select 1 from %1$I.customers c2 where c2.user_id = $1)', g.schema_pub) using new.id, new.email;
    exception when others then null;
    end;
  end loop;
  return new;
end $$;
revoke all on function mf.link_user_all() from public, anon, authenticated;

drop trigger if exists mf_link_user_all on auth.users;
create trigger mf_link_user_all after insert or update of email_confirmed_at, email on auth.users
  for each row execute function mf.link_user_all();
