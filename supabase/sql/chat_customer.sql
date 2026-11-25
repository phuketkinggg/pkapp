-- One customer for everything (feature chat_link, on by default).
-- A chat from Instagram, Facebook, WhatsApp or the website can be linked to a customer, or made into a new customer,
-- from the top of the chat. It then shows on that customer, with where they came from filled in.
-- Website and WhatsApp chats link by themselves when their email or phone matches exactly one customer.
-- Removing a customer no longer deletes their Instagram, Facebook, WhatsApp or website chats: they are kept, unlinked.

-- older databases without the social inbox: the column the WhatsApp link reads
alter table public.chats add column if not exists social_id text;

create or replace function private.chat_src(p_kind text) returns text language sql immutable set search_path = '' as $f$
  select case p_kind when 'ig' then 'Instagram' when 'fb' then 'Facebook' when 'wa' then 'WhatsApp' when 'web' then 'Website' end
$f$;

-- last 9 digits, so +66 81 234 5678 and 081 234 5678 match
create or replace function private.phone_key(p text) returns text language sql immutable set search_path = '' as $f$
  select case when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 8 then right(regexp_replace(p, '\D', '', 'g'), 9) end
$f$;

-- the one customer with this email or phone, or null when none or more than one
create or replace function private.customer_by_contact(p_contact text) returns uuid language plpgsql stable security definer set search_path = '' as $f$
declare em text := lower(btrim(coalesce(p_contact, ''))); ph text := private.phone_key(p_contact); ids uuid[];
begin
  if em ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    select array_agg(id) into ids from public.customers where lower(btrim(email)) = em;
  elsif ph is not null then
    select array_agg(id) into ids from public.customers where private.phone_key(phone) = ph;
  end if;
  return case when coalesce(array_length(ids, 1), 0) = 1 then ids[1] end;
end $f$;
revoke all on function private.chat_src(text), private.phone_key(text), private.customer_by_contact(text) from public, anon, authenticated;

create or replace function private.chat_staff_ok(p_chat uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select private.my_staff_id() is not null and private.chat_can(p_chat)
    and exists (select 1 from public.chats c where c.id = p_chat and c.kind in ('web','fb','ig','wa'))
$f$;
revoke all on function private.chat_staff_ok(uuid) from public, anon, authenticated;

-- who this chat could be: the linked customer, and customers that look like them
create or replace function public.chat_customer_find(p_chat uuid, p_q text default null) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare c public.chats; q text := btrim(coalesce(p_q, '')); out jsonb;
begin
  if not private.chat_staff_ok(p_chat) then raise exception 'You cannot open this chat.'; end if;
  select * into c from public.chats where id = p_chat;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'email', x.email, 'phone', x.phone) order by x.score desc, x.name), '[]'::jsonb) into out from (
    select cu.id, cu.name, cu.email, cu.phone,
      (case when lower(btrim(cu.email)) = lower(btrim(coalesce(c.visitor_contact, ''))) then 3 else 0 end
       + case when private.phone_key(cu.phone) is not null and private.phone_key(cu.phone) in (private.phone_key(c.visitor_contact), private.phone_key(c.social_id)) then 3 else 0 end
       + case when nullif(btrim(c.visitor_name), '') is not null and lower(cu.name) = lower(btrim(c.visitor_name)) then 2 else 0 end) score
    from public.customers cu
    where (q <> '' and (cu.name ilike '%' || q || '%' or cu.email ilike '%' || q || '%' or (private.phone_key(q) is not null and private.phone_key(cu.phone) = private.phone_key(q))))
       or (q = '' and (lower(btrim(cu.email)) = lower(btrim(coalesce(c.visitor_contact, '')))
         or (private.phone_key(cu.phone) is not null and private.phone_key(cu.phone) in (private.phone_key(c.visitor_contact), private.phone_key(c.social_id)))
         or (nullif(btrim(c.visitor_name), '') is not null and length(btrim(c.visitor_name)) >= 3 and cu.name ilike '%' || btrim(c.visitor_name) || '%')))
    limit 8) x;
  return jsonb_build_object('customer', (select jsonb_build_object('id', cu.id, 'name', cu.name) from public.customers cu where cu.id = c.customer_id),
    'name', c.visitor_name, 'contact', coalesce(c.visitor_contact, case when c.kind = 'wa' then c.social_id end), 'source', private.chat_src(c.kind), 'matches', out);
end $f$;

-- link a chat to a customer, or unlink it (p_customer null)
create or replace function public.chat_customer_set(p_chat uuid, p_customer uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare c public.chats;
begin
  if not private.feature('chat_link', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not private.chat_staff_ok(p_chat) then raise exception 'You cannot open this chat.'; end if;
  if p_customer is not null and not exists (select 1 from public.customers where id = p_customer) then raise exception 'Customer not found.'; end if;
  update public.chats set customer_id = p_customer where id = p_chat returning * into c;
  if p_customer is not null then
    update public.customers set lead_source = private.chat_src(c.kind) where id = p_customer and coalesce(lead_source, '') = '';
  end if;
  return jsonb_build_object('ok', true, 'customer_id', p_customer);
end $f$;

-- a new customer from a chat: name, email, phone; an email or phone that is already a customer links to them instead
create or replace function public.chat_customer_add(p_chat uuid, p_name text, p_email text, p_phone text) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare c public.chats; nm text := left(btrim(coalesce(p_name, '')), 120); em text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  ph text := nullif(btrim(coalesce(p_phone, '')), ''); cid uuid; found boolean := false;
begin
  if not private.feature('chat_link', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not private.chat_staff_ok(p_chat) then raise exception 'You cannot open this chat.'; end if;
  if nm = '' then raise exception 'Write their name.'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email does not look right.'; end if;
  select * into c from public.chats where id = p_chat;
  cid := coalesce(private.customer_by_contact(em), private.customer_by_contact(ph));
  if cid is not null then found := true;
  else
    insert into public.customers (name, email, phone, lead_source) values (nm, em, ph, private.chat_src(c.kind)) returning id into cid;
  end if;
  update public.chats set customer_id = cid where id = p_chat;
  if found then update public.customers set lead_source = private.chat_src(c.kind) where id = cid and coalesce(lead_source, '') = ''; end if;
  return jsonb_build_object('ok', true, 'customer_id', cid, 'existing', found);
end $f$;
revoke all on function public.chat_customer_find(uuid, text), public.chat_customer_set(uuid, uuid), public.chat_customer_add(uuid, text, text, text) from public, anon;
grant execute on function public.chat_customer_find(uuid, text), public.chat_customer_set(uuid, uuid), public.chat_customer_add(uuid, text, text, text) to authenticated;

-- website and WhatsApp chats link by themselves when the contact matches exactly one customer
create or replace function private.chat_auto_customer() returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  if new.customer_id is null and new.kind in ('web','wa') and private.feature('chat_link', true) then
    new.customer_id := coalesce(private.customer_by_contact(new.visitor_contact), case when new.kind = 'wa' then private.customer_by_contact(new.social_id) end);
  end if;
  return new;
end $f$;
revoke all on function private.chat_auto_customer() from public, anon, authenticated;
drop trigger if exists chats_auto_customer on public.chats;
create trigger chats_auto_customer before insert or update of visitor_contact, social_id on public.chats
  for each row execute function private.chat_auto_customer();

-- removing a customer keeps their social and website chats (unlinked); only their own app chats go
do $p$
declare d text; n text; o oid;
begin
  if to_regprocedure('public.customer_remove(uuid)') is not null then
    d := pg_get_functiondef('public.customer_remove(uuid)'::regprocedure);
    if position('kind in (''web'',''fb'',''ig'',''wa'')' in d) = 0 then
      n := replace(d, 'if to_regclass(''public.chats'') is not null then delete from public.chats where customer_id = p_id; end if;',
        'if to_regclass(''public.chats'') is not null then update public.chats set customer_id = null where customer_id = p_id and kind in (''web'',''fb'',''ig'',''wa''); delete from public.chats where customer_id = p_id; end if;');
      if n = d then raise notice 'chat_customer: customer_remove is different, skipped'; else execute n; end if;
    end if;
  end if;
  for o in select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'customer_delete_me' loop
    d := pg_get_functiondef(o);
    if position('kind in (''web'',''fb'',''ig'',''wa'')' in d) = 0 then
      n := replace(d, '    delete from public.chats where customer_id = cid;',
        '    update public.chats set customer_id = null where customer_id = cid and kind in (''web'',''fb'',''ig'',''wa'');
    delete from public.chats where customer_id = cid;');
      if n = d then raise notice 'chat_customer: customer_delete_me is different, skipped'; else execute n; end if;
    end if;
  end loop;
end $p$;

-- link the chats that already match exactly one customer
update public.chats ch set customer_id = coalesce(private.customer_by_contact(ch.visitor_contact), case when ch.kind = 'wa' then private.customer_by_contact(ch.social_id) end)
where ch.customer_id is null and ch.kind in ('web','wa')
  and coalesce(private.customer_by_contact(ch.visitor_contact), case when ch.kind = 'wa' then private.customer_by_contact(ch.social_id) end) is not null;

notify pgrst, 'reload schema';
