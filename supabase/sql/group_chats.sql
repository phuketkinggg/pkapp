-- Group chats with anyone: staff and customers (fighters, members, guests), named by the owner.
-- Optional: only staff can write (announcements). Every new message notifies the other members' phones.

alter table public.chats add column if not exists only_staff boolean not null default false;

-- announcements: customers read but do not write
do $$ declare s text;
begin
  s := pg_get_functiondef('public.chat_send(uuid,text)'::regprocedure);
  if s not like '%only_staff%' then
    s := replace(s, $a$  if b = '' then raise exception 'Type a message first.'; end if;$a$,
      $a$  if b = '' then raise exception 'Type a message first.'; end if;
  if me_s is null and exists (select 1 from public.chats where id = p_chat and only_staff) then raise exception 'Only the team writes in this group.'; end if;$a$);
    if s not like '%only_staff%' then raise exception 'chat_send patch did not apply'; end if;
    execute s;
  end if;
  s := pg_get_functiondef('public.chat_list()'::regprocedure);
  if s not like '%only_staff%' then
    s := replace(s, $a$'id', c.id, 'kind', c.kind,$a$, $a$'id', c.id, 'kind', c.kind, 'only_staff', c.only_staff,$a$);
    if s not like '%only_staff%' then raise exception 'chat_list patch did not apply'; end if;
    execute s;
  end if;
end $$;

create or replace function public.chat_group_mode(p_chat uuid, p_only_staff boolean) returns void language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change group chats.'; end if;
  update public.chats set only_staff = coalesce(p_only_staff, false) where id = p_chat and kind = 'group';
end $$;
revoke all on function public.chat_group_mode(uuid, boolean) from public, anon;
grant execute on function public.chat_group_mode(uuid, boolean) to authenticated;

-- phone notifications: anyone signed in can turn them on (staff and customers)
create or replace function public.push_sub_save(p_endpoint text, p_p256dh text, p_auth text) returns void language plpgsql security definer set search_path to '' as $$
begin
  if auth.uid() is null or (private.my_staff_id() is null and private.customer_id() is null) then raise exception 'Sign in first.'; end if;
  insert into public.push_subs (user_id, staff_id, endpoint, p256dh, auth) values (auth.uid(), private.my_staff_id(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, staff_id = excluded.staff_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now(), off_at = null;
end $$;

-- who to notify for one app message: the other members of the chat (and the desk for desk chats)
create or replace function public.chat_push_targets(p_message uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare m public.chat_messages; c public.chats; who text; users uuid[];
begin
  select * into m from public.chat_messages where id = p_message; if m.id is null then return null; end if;
  select * into c from public.chats where id = m.chat_id; if c.kind in ('web','fb','ig') then return null; end if;
  who := private.chat_who(m.sender_staff_id, m.sender_customer_id);
  select array_agg(distinct u) into users from (
    select s.user_id u from public.chat_members cm join public.staff s on s.id = cm.staff_id where cm.chat_id = c.id and cm.active and s.active and cm.staff_id is distinct from m.sender_staff_id
    union all select cu.user_id from public.chat_members cm join public.customers cu on cu.id = cm.customer_id where cm.chat_id = c.id and cm.active and cm.customer_id is distinct from m.sender_customer_id
    union all select cu.user_id from public.customers cu where c.kind = 'desk' and cu.id = c.customer_id and m.sender_customer_id is null
    union all select s.user_id from public.staff s where c.kind = 'desk' and m.sender_staff_id is null and s.active and s.role in ('manager','admin','front_desk','resort')
  ) q where u is not null;
  return jsonb_build_object('title', case when c.kind = 'group' then coalesce(c.title, 'Group') else coalesce(who, 'New message') end,
    'body', case when c.kind = 'group' then coalesce(who, '') || ': ' else '' end || left(m.body, 140), 'chat', c.id,
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth)) from public.push_subs p where p.off_at is null and p.user_id = any(coalesce(users, '{}'::uuid[]))), '[]'::jsonb));
end $$;
revoke all on function public.chat_push_targets(uuid) from public, anon, authenticated;

-- each new app message asks the chat function to send the notifications (never blocks the message)
create or replace function private.chat_push_send() returns trigger language plpgsql security definer set search_path to '' as $$
declare tok text; base text;
begin
  if new.from_visitor or coalesce(new.via, '') = 'meta' then return null; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  select value into base from private.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'app', 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $$;
drop trigger if exists chat_push on public.chat_messages;
create trigger chat_push after insert on public.chat_messages for each row execute function private.chat_push_send();
