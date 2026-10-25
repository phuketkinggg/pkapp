-- Clean up (AI package): scans customers, emails, staff, bookings and packages for duplicates, mess and things nobody uses,
-- returns a report, and applies only what the owner ticks. Every apply is checked again and written to public.cleanup_log.

create table if not exists public.cleanup_log (
  id uuid primary key default gen_random_uuid(), at timestamptz not null default now(), by_staff uuid references public.staff(id) on delete set null,
  items jsonb not null default '[]'::jsonb, results jsonb not null default '[]'::jsonb);
alter table public.cleanup_log enable row level security;
revoke all on public.cleanup_log from anon, authenticated;

create or replace function private.cleanup_ok() returns void language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' or not private.can('settings') then raise exception 'Only the owner or an admin with settings can clean up.'; end if;
  if not private.feature('cleanup', true) then raise exception 'Clean up is switched off (Settings, Features).'; end if;
end $$;

-- how much a customer is used: the one to keep in a merge
create or replace function private.cust_weight(p uuid) returns numeric language sql stable security definer set search_path to '' as $$
  select (select count(*) from public.purchases where customer_id = p) * 10 + (select count(*) from public.privates where customer_id = p) * 5
       + (select count(*) from public.stays where customer_id = p) * 10 + (select count(*) from public.checkins where customer_id = p)
       + case when (select user_id from public.customers where id = p) is not null then 50 else 0 end
       + extract(epoch from now() - (select created_at from public.customers where id = p)) / 86400 / 10000
$$;

-- a customer nothing points to (safe to delete)
create or replace function private.cust_unused(p uuid) returns boolean language sql stable security definer set search_path to '' as $$
  select not exists (select 1 from public.purchases where customer_id = p) and not exists (select 1 from public.privates where customer_id = p)
     and not exists (select 1 from public.stays where customer_id = p) and not exists (select 1 from public.checkins where customer_id = p)
     and not exists (select 1 from public.shop_orders where customer_id = p) and not exists (select 1 from public.payments where customer_id = p)
     and not exists (select 1 from public.chats where customer_id = p) and not exists (select 1 from public.chat_members where customer_id = p)
     and not exists (select 1 from public.invoices where customer_id = p) and not exists (select 1 from public.web_pkg_orders where customer_id = p)
     and not exists (select 1 from public.fights where fighter_customer_id = p)
     and (select user_id from public.customers where id = p) is null
$$;

create or replace function private.tidy_name(n text) returns text language sql immutable set search_path to '' as $$
  select case when x like '%@%' then x when x = lower(x) or x = upper(x) then initcap(x) else x end from (select regexp_replace(btrim(coalesce(n,'')), '\s+', ' ', 'g') x) q
$$;

create or replace function private.cleanup_items() returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare out jsonb := '[]'::jsonb; r record; t date := private.bkk_today();
begin
  -- 1. the same email on more than one customer: merge into the most used
  for r in select lower(btrim(email)) e, array_agg(id order by private.cust_weight(id) desc) ids, array_agg(name order by private.cust_weight(id) desc) names
           from public.customers where coalesce(btrim(email),'') <> '' and name not like 'Merged into %' group by 1 having count(*) > 1 loop
    out := out || jsonb_build_object('key', 'merge:' || r.ids[1] || ':' || array_to_string(r.ids[2:], ','), 'group', 'Customers', 'kind', 'merge', 'on', true,
      'title', 'Same email on ' || cardinality(r.ids) || ' customers: ' || r.e, 'detail', 'Keep ' || r.names[1] || ', merge in ' || array_to_string(r.names[2:], ', ') || '. Packages, privates, stays and messages all move to the one kept.',
      'keep', r.ids[1], 'drop', to_jsonb(r.ids[2:]));
  end loop;
  -- 2. the same phone number
  for r in select regexp_replace(phone, '\D', '', 'g') ph, array_agg(id order by private.cust_weight(id) desc) ids, array_agg(name order by private.cust_weight(id) desc) names
           from public.customers where length(regexp_replace(coalesce(phone,''), '\D', '', 'g')) >= 8 and name not like 'Merged into %' group by 1 having count(*) > 1 loop
    if not exists (select 1 from jsonb_array_elements(out) x where x->>'kind' = 'merge' and (x->>'keep')::uuid = any(r.ids) and exists (select 1 from jsonb_array_elements_text(x->'drop') d where d::uuid = any(r.ids))) then
      out := out || jsonb_build_object('key', 'merge:' || r.ids[1] || ':' || array_to_string(r.ids[2:], ','), 'group', 'Customers', 'kind', 'merge', 'on', true,
        'title', 'Same phone on ' || cardinality(r.ids) || ' customers: ' || r.ph, 'detail', 'Keep ' || r.names[1] || ', merge in ' || array_to_string(r.names[2:], ', ') || '.',
        'keep', r.ids[1], 'drop', to_jsonb(r.ids[2:]));
    end if;
  end loop;
  -- 3. the same name (could be two people: not ticked)
  for r in select lower(regexp_replace(btrim(name), '\s+', ' ', 'g')) nm, array_agg(id order by private.cust_weight(id) desc) ids,
                  array_agg(coalesce(nullif(email,''), nullif(phone,''), 'no contact') order by private.cust_weight(id) desc) ct,
                  bool_and(coalesce(btrim(email),'') = '' and coalesce(btrim(phone),'') = '') nocontact
           from public.customers where name not like 'Merged into %' and not is_agency and length(btrim(name)) > 2 group by 1 having count(*) > 1 loop
    -- placeholder names (one word, or many people, and nobody has an email or phone) are different visitors: skip
    if r.nocontact and (cardinality(r.ids) > 2 or position(' ' in r.nm) = 0) then continue; end if;
    if not exists (select 1 from jsonb_array_elements(out) x where x->>'kind' = 'merge' and (x->>'keep')::uuid = any(r.ids)) then
      out := out || jsonb_build_object('key', 'merge:' || r.ids[1] || ':' || array_to_string(r.ids[2:], ','), 'group', 'Customers', 'kind', 'merge', 'on', false,
        'title', 'Same name on ' || cardinality(r.ids) || ' customers: ' || initcap(r.nm), 'detail', 'Could be two different people, check first: ' || array_to_string(r.ct, ' / ') || '. Ticked, they merge into the most used one.',
        'keep', r.ids[1], 'drop', to_jsonb(r.ids[2:]));
    end if;
  end loop;
  -- 4. emails with capitals or spaces, and broken emails
  for r in select id, name, email from public.customers where email is not null and email <> lower(btrim(email)) and btrim(email) <> '' loop
    out := out || jsonb_build_object('key', 'email:' || r.id, 'group', 'Emails', 'kind', 'email_fix', 'on', true, 'title', r.name || ': tidy the email',
      'detail', r.email || ' becomes ' || lower(btrim(r.email)), 'id', r.id);
  end loop;
  for r in select id, name, email from public.customers where coalesce(btrim(email),'') <> '' and btrim(email) !~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' loop
    out := out || jsonb_build_object('key', 'bademail:' || r.id, 'group', 'Emails', 'kind', 'email_clear', 'on', false, 'title', r.name || ': this email does not work',
      'detail', '"' || r.email || '" is not a real email address. Ticked, it is taken off (emails to it would bounce).', 'id', r.id);
  end loop;
  -- 5. unsubscribed but still marked yes to emails
  for r in select id, name from public.customers where unsubscribed_at is not null and marketing_ok is distinct from false loop
    out := out || jsonb_build_object('key', 'unsub:' || r.id, 'group', 'Emails', 'kind', 'unsub_fix', 'on', true, 'title', r.name || ': unsubscribed, still marked yes to emails',
      'detail', 'Marked no to emails, as they asked.', 'id', r.id);
  end loop;
  -- 6. names with extra spaces or all small or all capital letters
  for r in select id, name from public.customers where name like '%@%' and name not like 'Merged into %' loop
    out := out || jsonb_build_object('key', 'nameemail:' || r.id, 'group', 'Customers', 'kind', 'note', 'on', false, 'title', 'Name is an email: ' || r.name,
      'detail', 'Open the customer and type their real name.', 'id', r.id);
  end loop;
  for r in select id, name from public.customers where name not like 'Merged into %' and name <> private.tidy_name(name) loop
    out := out || jsonb_build_object('key', 'name:' || r.id, 'group', 'Customers', 'kind', 'name_fix', 'on', true, 'title', 'Tidy a name',
      'detail', '"' || r.name || '" becomes "' || private.tidy_name(r.name) || '"', 'id', r.id);
  end loop;
  -- 7. empty customers: no email, phone or login, nothing booked or bought, older than 30 days; and leftovers of merges
  for r in select id, name, created_at from public.customers c where not c.is_agency and c.created_at < now() - interval '30 days'
             and coalesce(btrim(c.email),'') = '' and coalesce(btrim(c.phone),'') = '' and private.cust_unused(c.id) and c.name not like 'Merged into %' loop
    out := out || jsonb_build_object('key', 'empty:' || r.id, 'group', 'Customers', 'kind', 'cust_delete', 'on', true, 'title', 'Empty customer: ' || r.name,
      'detail', 'No email, phone or app login, never bought, booked or checked in. Added ' || to_char(r.created_at, 'DD Mon YYYY') || '.', 'id', r.id);
  end loop;
  for r in select id, name from public.customers c where c.name like 'Merged into %' and private.cust_unused(c.id) loop
    out := out || jsonb_build_object('key', 'merged:' || r.id, 'group', 'Customers', 'kind', 'cust_delete', 'on', true, 'title', 'Leftover from a merge: ' || r.name,
      'detail', 'Everything already moved to the customer it was merged into.', 'id', r.id);
  end loop;
  -- 8. private requests never answered, now in the past
  for r in select p.id, p.date, to_char(p.start_time,'HH24:MI') tm, coalesce(c.name, p.guest_name, 'Guest') who from public.privates p left join public.customers c on c.id = p.customer_id
           where p.status = 'requested' and p.date < t loop
    out := out || jsonb_build_object('key', 'oldreq:' || r.id, 'group', 'Bookings', 'kind', 'priv_cancel', 'on', true, 'title', 'Old private request: ' || r.who,
      'detail', 'Asked for ' || to_char(r.date, 'DD Mon') || ' ' || coalesce(r.tm,'') || ', never confirmed. Ticked, it is cancelled.', 'id', r.id);
  end loop;
  -- 9. confirmed privates in the past, not marked done (not ticked: check first)
  for r in select p.id, p.date, to_char(p.start_time,'HH24:MI') tm, coalesce(c.name, p.guest_name, 'Guest') who, p.arrived_at is not null arrived from public.privates p left join public.customers c on c.id = p.customer_id
           where p.status = 'confirmed' and p.date < t - 1 loop
    out := out || jsonb_build_object('key', 'pastpriv:' || r.id, 'group', 'Bookings', 'kind', 'priv_done', 'on', r.arrived, 'title', 'Private still open: ' || r.who,
      'detail', to_char(r.date, 'DD Mon') || ' ' || coalesce(r.tm,'') || case when r.arrived then ', they checked in. Ticked, it is marked done (it counts for coach pay).' else ', they never checked in. Ticked, it is marked done anyway: untick if it did not happen.' end, 'id', r.id);
  end loop;
  -- 10. app orders never paid or used, older than 14 days
  for r in select k.id, k.package_name, k.purchased_on, coalesce(c.name,'?') who from public.purchases k left join public.customers c on c.id = k.customer_id
           where k.ordered_in_app and not k.cancelled and coalesce(k.paid_thb,0) = 0 and not coalesce(k.paid,false) and k.purchased_on < t - 14
             and not exists (select 1 from public.checkins x where x.purchase_id = k.id) and not exists (select 1 from public.privates x where x.purchase_id = k.id) loop
    out := out || jsonb_build_object('key', 'order:' || r.id, 'group', 'Packages', 'kind', 'order_cancel', 'on', true, 'title', 'Unpaid app order: ' || r.who || ', ' || r.package_name,
      'detail', 'Ordered ' || to_char(r.purchased_on, 'DD Mon') || ', never paid or used. Ticked, it is cancelled (it stops showing as owed).', 'id', r.id);
  end loop;
  -- 11. packages switched off and never sold
  for r in select k.id, k.name from public.packages k where not k.active and not exists (select 1 from public.purchases p where p.package_id = k.id)
             and not exists (select 1 from public.web_pkg_orders o where o.package_id = k.id)
             and not exists (select 1 from public.app_settings a where a.value like '%' || k.id || '%') loop
    out := out || jsonb_build_object('key', 'pkg:' || r.id, 'group', 'Packages', 'kind', 'pkg_delete', 'on', true, 'title', 'Unused package: ' || r.name,
      'detail', 'Switched off and never sold. Ticked, it is deleted from the list.', 'id', r.id);
  end loop;
  -- 12. staff: the same name twice, and coaches with nothing for 60 days (not ticked)
  for r in select lower(btrim(name)) nm, count(*) n from public.staff where active group by 1 having count(*) > 1 loop
    out := out || jsonb_build_object('key', 'staffdup:' || r.nm, 'group', 'Staff', 'kind', 'note', 'on', false, 'title', 'Two staff called ' || initcap(r.nm),
      'detail', 'Check in Staff which one is right and switch the other off.');
  end loop;
  for r in select s.id, s.name from public.staff s where s.active and s.role in ('coach','housekeeping','maintenance','kitchen','front_desk','resort') and s.created_at < now() - interval '60 days'
             and not exists (select 1 from public.privates p where (p.coach_id = s.id or p.preferred_coach_id = s.id) and p.date > t - 60)
             and not exists (select 1 from public.classes k where s.id = any(k.coach_ids))
             and s.user_id is null loop
    out := out || jsonb_build_object('key', 'staffidle:' || r.id, 'group', 'Staff', 'kind', 'staff_off', 'on', false, 'title', 'No activity: ' || r.name,
      'detail', 'No app login, no privates in 60 days and no classes. Ticked, they are marked not working here now (nothing is deleted).', 'id', r.id);
  end loop;
  return out;
end $$;

create or replace function public.cleanup_scan() returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  perform private.cleanup_ok();
  return jsonb_build_object('items', private.cleanup_items(), 'last', (select jsonb_build_object('at', l.at, 'by', s.name, 'n', jsonb_array_length(l.results)) from public.cleanup_log l left join public.staff s on s.id = l.by_staff order by l.at desc limit 1));
end $$;

create or replace function public.cleanup_apply(p_keys text[]) returns jsonb language plpgsql security definer set search_path to '' as $$
declare it jsonb; res jsonb := '[]'::jsonb; ok boolean; msg text; d text; done_items jsonb := '[]'::jsonb;
begin
  perform private.cleanup_ok();
  for it in select x from jsonb_array_elements(private.cleanup_items()) x where x->>'key' = any(coalesce(p_keys, '{}')) loop
    ok := true; msg := 'Done';
    begin
      case it->>'kind'
        when 'merge' then for d in select jsonb_array_elements_text(it->'drop') loop perform public.merge_customers((it->>'keep')::uuid, d::uuid); end loop;
        when 'email_fix' then update public.customers set email = lower(btrim(email)) where id = (it->>'id')::uuid;
        when 'email_clear' then update public.customers set email = null where id = (it->>'id')::uuid;
        when 'unsub_fix' then update public.customers set marketing_ok = false where id = (it->>'id')::uuid;
        when 'name_fix' then update public.customers set name = private.tidy_name(name) where id = (it->>'id')::uuid;
        when 'cust_delete' then if private.cust_unused((it->>'id')::uuid) then delete from public.customers where id = (it->>'id')::uuid; else ok := false; msg := 'Now in use, kept'; end if;
        when 'priv_cancel' then update public.privates set status = 'cancelled', decline_reason = coalesce(decline_reason, 'Cleaned up: never confirmed') where id = (it->>'id')::uuid and status = 'requested';
        when 'priv_done' then update public.privates set status = 'done' where id = (it->>'id')::uuid and status = 'confirmed';
        when 'order_cancel' then update public.purchases set cancelled = true where id = (it->>'id')::uuid and not cancelled and coalesce(paid_thb,0) = 0;
        when 'pkg_delete' then delete from public.packages where id = (it->>'id')::uuid and not active;
        when 'staff_off' then update public.staff set active = false where id = (it->>'id')::uuid;
        else ok := false; msg := 'Nothing to do here, check it yourself';
      end case;
    exception when others then ok := false; msg := sqlerrm;
    end;
    res := res || jsonb_build_object('key', it->>'key', 'title', it->>'title', 'ok', ok, 'msg', msg);
    done_items := done_items || it;
  end loop;
  insert into public.cleanup_log (by_staff, items, results) values (private.my_staff_id(), done_items, res);
  return res;
end $$;

revoke all on function public.cleanup_scan() from public, anon;
revoke all on function public.cleanup_apply(text[]) from public, anon;
grant execute on function public.cleanup_scan() to authenticated;
grant execute on function public.cleanup_apply(text[]) to authenticated;
revoke all on function private.cleanup_items() from public, anon, authenticated;
