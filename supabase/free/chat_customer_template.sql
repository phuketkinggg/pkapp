delete from mf.template where name like 'chat_customer:%';
insert into mf.template (ord, phase, kind, name, sql) values (305101, 3, 'patch', 'chat_customer:305101', $TPL$alter table __P__.chats add column if not exists social_id text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405101, 4, 'patch', 'chat_customer:405101', $TPL$create or replace function __Q__.chat_src(p_kind text) returns text language sql immutable set search_path = '' as $f$
  select case p_kind when 'ig' then 'Instagram' when 'fb' then 'Facebook' when 'wa' then 'WhatsApp' when 'web' then 'Website' end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405102, 4, 'patch', 'chat_customer:405102', $TPL$create or replace function __Q__.phone_key(p text) returns text language sql immutable set search_path = '' as $f$
  select case when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 8 then right(regexp_replace(p, '\D', '', 'g'), 9) end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405103, 4, 'patch', 'chat_customer:405103', $TPL$create or replace function __Q__.customer_by_contact(p_contact text) returns uuid language plpgsql stable security definer set search_path = '' as $f$
declare em text := lower(btrim(coalesce(p_contact, ''))); ph text := __Q__.phone_key(p_contact); ids uuid[];
begin
  if em ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    select array_agg(id) into ids from __P__.customers where lower(btrim(email)) = em;
  elsif ph is not null then
    select array_agg(id) into ids from __P__.customers where __Q__.phone_key(phone) = ph;
  end if;
  return case when coalesce(array_length(ids, 1), 0) = 1 then ids[1] end;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199201, 11, 'patch', 'chat_customer:1199201', $TPL$revoke all on function __Q__.chat_src(text), __Q__.phone_key(text), __Q__.customer_by_contact(text) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405104, 4, 'patch', 'chat_customer:405104', $TPL$create or replace function __Q__.chat_staff_ok(p_chat uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select __Q__.my_staff_id() is not null and __Q__.chat_can(p_chat)
    and exists (select 1 from __P__.chats c where c.id = p_chat and c.kind in ('web','fb','ig','wa'))
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199202, 11, 'patch', 'chat_customer:1199202', $TPL$revoke all on function __Q__.chat_staff_ok(uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405105, 4, 'patch', 'chat_customer:405105', $TPL$create or replace function __P__.chat_customer_find(p_chat uuid, p_q text default null) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare c __P__.chats; q text := btrim(coalesce(p_q, '')); out jsonb;
begin
  if not __Q__.chat_staff_ok(p_chat) then raise exception 'You cannot open this chat.'; end if;
  select * into c from __P__.chats where id = p_chat;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'email', x.email, 'phone', x.phone) order by x.score desc, x.name), '[]'::jsonb) into out from (
    select cu.id, cu.name, cu.email, cu.phone,
      (case when lower(btrim(cu.email)) = lower(btrim(coalesce(c.visitor_contact, ''))) then 3 else 0 end
       + case when __Q__.phone_key(cu.phone) is not null and __Q__.phone_key(cu.phone) in (__Q__.phone_key(c.visitor_contact), __Q__.phone_key(c.social_id)) then 3 else 0 end
       + case when nullif(btrim(c.visitor_name), '') is not null and lower(cu.name) = lower(btrim(c.visitor_name)) then 2 else 0 end) score
    from __P__.customers cu
    where (q <> '' and (cu.name ilike '%' || q || '%' or cu.email ilike '%' || q || '%' or (__Q__.phone_key(q) is not null and __Q__.phone_key(cu.phone) = __Q__.phone_key(q))))
       or (q = '' and (lower(btrim(cu.email)) = lower(btrim(coalesce(c.visitor_contact, '')))
         or (__Q__.phone_key(cu.phone) is not null and __Q__.phone_key(cu.phone) in (__Q__.phone_key(c.visitor_contact), __Q__.phone_key(c.social_id)))
         or (nullif(btrim(c.visitor_name), '') is not null and length(btrim(c.visitor_name)) >= 3 and cu.name ilike '%' || btrim(c.visitor_name) || '%')))
    limit 8) x;
  return jsonb_build_object('customer', (select jsonb_build_object('id', cu.id, 'name', cu.name) from __P__.customers cu where cu.id = c.customer_id),
    'name', c.visitor_name, 'contact', coalesce(c.visitor_contact, case when c.kind = 'wa' then c.social_id end), 'source', __Q__.chat_src(c.kind), 'matches', out);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405106, 4, 'patch', 'chat_customer:405106', $TPL$create or replace function __P__.chat_customer_set(p_chat uuid, p_customer uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare c __P__.chats;
begin
  if not __Q__.feature('chat_link', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not __Q__.chat_staff_ok(p_chat) then raise exception 'You cannot open this chat.'; end if;
  if p_customer is not null and not exists (select 1 from __P__.customers where id = p_customer) then raise exception 'Customer not found.'; end if;
  update __P__.chats set customer_id = p_customer where id = p_chat returning * into c;
  if p_customer is not null then
    update __P__.customers set lead_source = __Q__.chat_src(c.kind) where id = p_customer and coalesce(lead_source, '') = '';
  end if;
  return jsonb_build_object('ok', true, 'customer_id', p_customer);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405107, 4, 'patch', 'chat_customer:405107', $TPL$create or replace function __P__.chat_customer_add(p_chat uuid, p_name text, p_email text, p_phone text) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare c __P__.chats; nm text := left(btrim(coalesce(p_name, '')), 120); em text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  ph text := nullif(btrim(coalesce(p_phone, '')), ''); cid uuid; found boolean := false;
begin
  if not __Q__.feature('chat_link', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not __Q__.chat_staff_ok(p_chat) then raise exception 'You cannot open this chat.'; end if;
  if nm = '' then raise exception 'Write their name.'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email does not look right.'; end if;
  select * into c from __P__.chats where id = p_chat;
  cid := coalesce(__Q__.customer_by_contact(em), __Q__.customer_by_contact(ph));
  if cid is not null then found := true;
  else
    insert into __P__.customers (name, email, phone, lead_source) values (nm, em, ph, __Q__.chat_src(c.kind)) returning id into cid;
  end if;
  update __P__.chats set customer_id = cid where id = p_chat;
  if found then update __P__.customers set lead_source = __Q__.chat_src(c.kind) where id = cid and coalesce(lead_source, '') = ''; end if;
  return jsonb_build_object('ok', true, 'customer_id', cid, 'existing', found);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199203, 11, 'patch', 'chat_customer:1199203', $TPL$revoke all on function __P__.chat_customer_find(uuid, text), __P__.chat_customer_set(uuid, uuid), __P__.chat_customer_add(uuid, text, text, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199204, 11, 'patch', 'chat_customer:1199204', $TPL$grant execute on function __P__.chat_customer_find(uuid, text), __P__.chat_customer_set(uuid, uuid), __P__.chat_customer_add(uuid, text, text, text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (405108, 4, 'patch', 'chat_customer:405108', $TPL$create or replace function __Q__.chat_auto_customer() returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  if new.customer_id is null and new.kind in ('web','wa') and __Q__.feature('chat_link', true) then
    new.customer_id := coalesce(__Q__.customer_by_contact(new.visitor_contact), case when new.kind = 'wa' then __Q__.customer_by_contact(new.social_id) end);
  end if;
  return new;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1199205, 11, 'patch', 'chat_customer:1199205', $TPL$revoke all on function __Q__.chat_auto_customer() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903301, 9, 'patch', 'chat_customer:903301', $TPL$drop trigger if exists chats_auto_customer on __P__.chats;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (903302, 9, 'patch', 'chat_customer:903302', $TPL$create trigger chats_auto_customer before insert or update of visitor_contact, social_id on __P__.chats
  for each row execute function __Q__.chat_auto_customer();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003701, 10, 'patch', 'chat_customer:1003701', $TPL$do $p$
declare d text; n text; o oid;
begin
  if to_regprocedure('__P__.customer_remove(uuid)') is not null then
    d := pg_get_functiondef('__P__.customer_remove(uuid)'::regprocedure);
    if position('kind in (''web'',''fb'',''ig'',''wa'')' in d) = 0 then
      n := replace(d, 'if to_regclass(''__P__.chats'') is not null then delete from __P__.chats where customer_id = p_id; end if;',
        'if to_regclass(''__P__.chats'') is not null then update __P__.chats set customer_id = null where customer_id = p_id and kind in (''web'',''fb'',''ig'',''wa''); delete from __P__.chats where customer_id = p_id; end if;');
      if n = d then raise notice 'chat_customer: customer_remove is different, skipped'; else execute n; end if;
    end if;
  end if;
  for o in select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'customer_delete_me' loop
    d := pg_get_functiondef(o);
    if position('kind in (''web'',''fb'',''ig'',''wa'')' in d) = 0 then
      n := replace(d, '    delete from __P__.chats where customer_id = cid;',
        '    update __P__.chats set customer_id = null where customer_id = cid and kind in (''web'',''fb'',''ig'',''wa'');
    delete from __P__.chats where customer_id = cid;');
      if n = d then raise notice 'chat_customer: customer_delete_me is different, skipped'; else execute n; end if;
    end if;
  end loop;
end $p$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003702, 10, 'patch', 'chat_customer:1003702', $TPL$update __P__.chats ch set customer_id = coalesce(__Q__.customer_by_contact(ch.visitor_contact), case when ch.kind = 'wa' then __Q__.customer_by_contact(ch.social_id) end)
where ch.customer_id is null and ch.kind in ('web','wa')
  and coalesce(__Q__.customer_by_contact(ch.visitor_contact), case when ch.kind = 'wa' then __Q__.customer_by_contact(ch.social_id) end) is not null;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'chat_customer:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
