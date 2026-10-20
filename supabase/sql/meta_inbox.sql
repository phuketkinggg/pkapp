-- Facebook Messenger and Instagram messages in the app's Messages, next to website chat.
-- Incoming: the "meta" edge function (Meta webhook) calls public.meta_incoming.
-- Outgoing: a staff reply in a Facebook or Instagram chat is marked "sending" and handed to the meta function, which sends it and records the result.

alter table public.chats drop constraint if exists chats_kind_check2;
alter table public.chats add constraint chats_kind_check2 check (kind = any (array['desk','coach','staff','group','web','fb','ig']));
alter table public.chats add column if not exists social_id text;
alter table public.chats add column if not exists social_pic text;
alter table public.chats add column if not exists last_in_at timestamptz;
create unique index if not exists chats_social on public.chats(kind, social_id) where social_id is not null;

alter table public.chat_messages add column if not exists ext_id text;
alter table public.chat_messages add column if not exists via text;
alter table public.chat_messages add column if not exists send_status text;
alter table public.chat_messages add column if not exists send_error text;
alter table public.chat_messages add column if not exists media jsonb;
create unique index if not exists chat_messages_ext on public.chat_messages(ext_id) where ext_id is not null;

-- the desk sees Facebook and Instagram chats like website chats
create or replace function private.chat_can(p_chat uuid) returns boolean language sql stable security definer set search_path='' as $f$
  select p_chat is not null and exists (select 1 from public.chats c0 where c0.id = p_chat) and (
    coalesce(private.staff_role() = 'manager', false)
    or exists (select 1 from public.chats c where c.id = p_chat and c.kind in ('desk','web','fb','ig') and private.is_desk())
    or exists (select 1 from public.chat_members m where m.chat_id = p_chat and m.active
               and ((m.staff_id is not null and m.staff_id = private.my_staff_id())
                 or (m.customer_id is not null and m.customer_id = private.customer_id()))))
$f$;

create or replace function public.chat_list() returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare me_s uuid := private.my_staff_id(); me_c uuid := private.customer_id(); desk boolean := private.is_desk(); res jsonb;
begin
  if auth.uid() is null or (me_s is null and me_c is null) then raise exception 'Sign in first.'; end if;
  select coalesce(jsonb_agg(x order by x->>'last_at' desc), '[]'::jsonb) into res from (
    select jsonb_build_object(
      'id', c.id, 'kind', c.kind, 'last_at', c.last_at, 'customer_id', c.customer_id, 'title_raw', c.title,
      'in_chat', (c.kind in ('desk','web','fb','ig') and desk) or exists (select 1 from public.chat_members m where m.chat_id = c.id and m.active
                   and ((me_s is not null and m.staff_id = me_s) or (me_s is null and m.customer_id = me_c))),
      'title', case
        when c.kind = 'group' then coalesce(c.title, 'Group')
        when c.kind = 'web' then 'Website: ' || coalesce(nullif(c.visitor_name,''), 'visitor')
        when c.kind = 'fb' then 'Facebook: ' || coalesce(nullif(c.visitor_name,''), 'Messenger user')
        when c.kind = 'ig' then 'Instagram: ' || coalesce(nullif(c.visitor_name,''), 'Instagram user')
        when c.kind = 'desk' then case when me_s is null then 'Phuket King front desk' else (select cu.name from public.customers cu where cu.id = c.customer_id) || ' (front desk)' end
        else coalesce((select string_agg(coalesce(s.name, cu.name), ', ' order by coalesce(s.name, cu.name)) from public.chat_members m
               left join public.staff s on s.id = m.staff_id left join public.customers cu on cu.id = m.customer_id
               where m.chat_id = c.id and m.active and m.staff_id is distinct from me_s and (me_s is not null or m.customer_id is distinct from me_c)), 'Chat') end,
      'visitor', case when c.kind = 'web' then jsonb_build_object('name', c.visitor_name, 'contact', c.visitor_contact, 'page', c.visitor_page,
                   'here', coalesce(c.visitor_seen_at > now() - interval '1 minute', false))
                 when c.kind in ('fb','ig') then jsonb_build_object('name', c.visitor_name, 'pic', c.social_pic, 'contact', c.visitor_contact,
                   'last_in', c.last_in_at, 'open', coalesce(c.last_in_at > now() - interval '24 hours', false)) end,
      'members', (select coalesce(jsonb_agg(jsonb_build_object('staff_id', m.staff_id, 'customer_id', m.customer_id, 'name', coalesce(s.name, cu.name))), '[]'::jsonb)
                  from public.chat_members m left join public.staff s on s.id = m.staff_id left join public.customers cu on cu.id = m.customer_id where m.chat_id = c.id and m.active),
      'last', (select jsonb_build_object('body', left(mm.body, 120), 'at', mm.created_at,
                 'who', case when mm.from_visitor then coalesce(nullif(c.visitor_name,''),'Visitor') when mm.via = 'meta' then 'Team' else private.chat_who(mm.sender_staff_id, mm.sender_customer_id) end)
               from public.chat_messages mm where mm.chat_id = c.id order by mm.created_at desc limit 1),
      'unread', (select count(*) from public.chat_messages mm where mm.chat_id = c.id
                 and not coalesce((me_s is not null and mm.sender_staff_id = me_s) or (me_s is null and mm.sender_customer_id = me_c), false)
                 and mm.created_at > coalesce((select r.read_at from public.chat_reads r where r.user_id = auth.uid() and r.chat_id = c.id), '-infinity'))
    ) x
    from public.chats c where private.chat_can(c.id) and (c.kind not in ('web','fb','ig') or c.last_at > now() - interval '60 days')
  ) q;
  return res;
end $f$;

create or replace function public.chat_messages(p_chat uuid, p_after timestamptz default null) returns jsonb language plpgsql security definer set search_path='' as $f$
declare me_s uuid := private.my_staff_id(); me_c uuid := private.customer_id(); res jsonb; vn text;
begin
  if not private.chat_can(p_chat) then raise exception 'You are not in this chat.'; end if;
  select coalesce(nullif(visitor_name,''),'Visitor') into vn from public.chats where id = p_chat;
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'body', m.body, 'at', m.created_at,
           'who', case when m.from_visitor then vn when m.via = 'meta' then 'Team (in the Meta app)' else private.chat_who(m.sender_staff_id, m.sender_customer_id) end,
           'mine', coalesce((me_s is not null and m.sender_staff_id = me_s) or (me_c is not null and me_s is null and m.sender_customer_id = me_c), false),
           'staff', m.sender_staff_id is not null or m.via = 'meta', 'status', m.send_status, 'error', m.send_error, 'media', m.media) order by m.created_at), '[]'::jsonb) into res
  from (select * from public.chat_messages where chat_id = p_chat and (p_after is null or created_at > p_after) order by created_at desc limit 200) m;
  insert into public.chat_reads (user_id, chat_id, read_at) values (auth.uid(), p_chat, now())
    on conflict (user_id, chat_id) do update set read_at = now();
  return res;
end $f$;

-- a message arrives from Facebook or Instagram (or one the team sent from the Meta app: echo)
create or replace function public.meta_incoming(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare k text := p->>'kind'; sid text := p->>'social_id'; cid uuid; isnew boolean := false; echo boolean := coalesce((p->>'echo')::boolean, false);
  b text := left(coalesce(nullif(btrim(p->>'text'),''), case when jsonb_array_length(coalesce(p->'media','[]'::jsonb)) > 0 then '[Photo or file]' else '[Message]' end), 2000);
  at timestamptz := coalesce(nullif(p->>'at','')::timestamptz, now()); nid uuid;
begin
  if k not in ('fb','ig') or coalesce(sid,'') = '' then raise exception 'bad message'; end if;
  select id into cid from public.chats where kind=k and social_id=sid;
  if cid is null then
    insert into public.chats(kind, social_id, visitor_name, social_pic, last_at) values (k, sid, left(nullif(p->>'name',''),80), nullif(p->>'pic',''), at)
      on conflict (kind, social_id) where social_id is not null do nothing returning id into cid;
    if cid is null then select id into cid from public.chats where kind=k and social_id=sid; else isnew := true; end if;
  end if;
  if nullif(p->>'name','') is not null then update public.chats set visitor_name=left(p->>'name',80), social_pic=coalesce(nullif(p->>'pic',''), social_pic) where id=cid and coalesce(visitor_name,'') = ''; end if;
  insert into public.chat_messages(chat_id, body, created_at, from_visitor, ext_id, via, media, send_status)
    values (cid, b, at, not echo, nullif(p->>'mid',''), case when echo then 'meta' end, nullif(p->'media','[]'::jsonb), case when echo then 'sent' end)
    on conflict (ext_id) where ext_id is not null do nothing returning id into nid;
  if nid is null then return jsonb_build_object('chat_id', cid, 'dup', true); end if;
  update public.chats set last_at=greatest(coalesce(last_at, at), at), last_in_at=case when echo then last_in_at else greatest(coalesce(last_in_at, at), at) end where id=cid;
  return jsonb_build_object('chat_id', cid, 'new_chat', isnew, 'needs_name', (select coalesce(visitor_name,'') = '' from public.chats where id=cid));
end $f$;
revoke all on function public.meta_incoming(jsonb) from public, anon, authenticated;
grant execute on function public.meta_incoming(jsonb) to service_role;

-- a staff reply in a Facebook or Instagram chat: hand it to the meta function to send
create or replace function private.meta_out_mark() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if new.sender_staff_id is not null and new.ext_id is null and exists (select 1 from public.chats c where c.id=new.chat_id and c.kind in ('fb','ig')) then
    new.send_status := 'sending';
  end if;
  return new;
end $f$;
drop trigger if exists chat_meta_mark on public.chat_messages;
create trigger chat_meta_mark before insert on public.chat_messages for each row execute function private.meta_out_mark();

create or replace function private.meta_out_send() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if new.send_status = 'sending' then
    perform net.http_post(url := 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/meta',
      headers := jsonb_build_object('Content-Type','application/json','x-sync-token',(select value from private.sync_settings where key='sync_token')),
      body := jsonb_build_object('mode','send','id',new.id), timeout_milliseconds := 30000);
  end if;
  return null;
end $f$;
drop trigger if exists chat_meta_send on public.chat_messages;
create trigger chat_meta_send after insert on public.chat_messages for each row execute function private.meta_out_send();

create or replace function public.meta_out(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $f$
  select jsonb_build_object('id', m.id, 'body', m.body, 'kind', c.kind, 'social_id', c.social_id, 'last_in_at', c.last_in_at, 'status', m.send_status)
  from public.chat_messages m join public.chats c on c.id=m.chat_id where m.id=p_id
$f$;
revoke all on function public.meta_out(uuid) from public, anon, authenticated;
grant execute on function public.meta_out(uuid) to service_role;

-- the webhook verify token Meta sends when the callback is set up (kept in the database, not in the code)
insert into private.sync_settings(key, value) values ('meta_verify', replace(gen_random_uuid()::text, '-', '')) on conflict (key) do nothing;
create or replace function public.meta_verify_ok(p_token text) returns boolean language sql stable security definer set search_path='' as $f$
  select coalesce(p_token,'') <> '' and exists (select 1 from private.sync_settings where key='meta_verify' and value=p_token)
$f$;
revoke all on function public.meta_verify_ok(text) from public, anon, authenticated;
grant execute on function public.meta_verify_ok(text) to service_role;
