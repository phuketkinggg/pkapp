-- Block someone in chats (feature: chat_block). Anyone in a chat can block the person who wrote a message.
-- Their messages are hidden from you in every chat, you get no phone notices from them, and managers and the
-- front desk get a notice (as a reported message) so the team can look at it. Settings, Blocked people, to undo.

create table if not exists public.chat_blocks (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null,
  blocked_staff uuid references public.staff(id) on delete cascade,
  blocked_customer uuid references public.customers(id) on delete cascade,
  check ((blocked_staff is null) <> (blocked_customer is null))
);
create unique index if not exists chat_blocks_staff on public.chat_blocks (user_id, blocked_staff) where blocked_staff is not null;
create unique index if not exists chat_blocks_customer on public.chat_blocks (user_id, blocked_customer) where blocked_customer is not null;
create index if not exists chat_blocks_user on public.chat_blocks (user_id);
alter table public.chat_blocks enable row level security;
revoke all on public.chat_blocks from anon, authenticated;

create or replace function public.chat_block(p_message uuid) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare m public.chat_messages; c public.chats; me_s uuid := private.my_staff_id(); me_c uuid := private.customer_id(); who text; me_who text;
begin
  if auth.uid() is null or (me_s is null and me_c is null) then raise exception 'Sign in first.'; end if;
  if not private.feature('chat_block', true) then raise exception 'Blocking is turned off.'; end if;
  select * into m from public.chat_messages where id = p_message;
  if m.id is null or not private.chat_can(m.chat_id) then raise exception 'That message was not found.'; end if;
  if m.sender_staff_id is null and m.sender_customer_id is null then raise exception 'This message cannot be blocked.'; end if;
  if (me_s is not null and m.sender_staff_id = me_s) or (me_c is not null and m.sender_customer_id = me_c) then raise exception 'That is your own message.'; end if;
  if (select count(*) from public.chat_blocks where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'You have blocked a lot of people. The team will look at it.'; end if;
  insert into public.chat_blocks (user_id, blocked_staff, blocked_customer)
    values (auth.uid(), m.sender_staff_id, case when m.sender_staff_id is null then m.sender_customer_id end)
    on conflict do nothing;
  who := coalesce(private.chat_who(m.sender_staff_id, m.sender_customer_id), 'Someone');
  me_who := coalesce(private.chat_who(me_s, case when me_s is null then me_c end), 'Someone');
  select * into c from public.chats where id = m.chat_id;
  begin
    insert into public.notices (kind, customer_id, ref_id, title, detail)
    values ('chat_report', m.sender_customer_id, m.chat_id, me_who || ' blocked ' || who,
      'In ' || case when c.kind = 'group' then coalesce(c.title, 'a group') else 'a chat' end || '. Their last message: "' || left(m.body, 200) || '". Tap to open the chat.');
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'who', who);
end $f$;

create or replace function public.chat_blocks_mine() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'at', b.created_at,
    'name', coalesce(private.chat_who(b.blocked_staff, b.blocked_customer), 'Someone')) order by b.created_at desc), '[]'::jsonb)
  from public.chat_blocks b where b.user_id = auth.uid()
$f$;

create or replace function public.chat_unblock(p_id uuid) returns void language sql security definer set search_path to '' as $f$
  delete from public.chat_blocks where id = p_id and user_id = auth.uid()
$f$;

revoke all on function public.chat_block(uuid) from public, anon;
revoke all on function public.chat_blocks_mine() from public, anon;
revoke all on function public.chat_unblock(uuid) from public, anon;
grant execute on function public.chat_block(uuid) to authenticated;
grant execute on function public.chat_blocks_mine() to authenticated;
grant execute on function public.chat_unblock(uuid) to authenticated;

-- hide blocked people's messages, and send no phone notices from them (patches; checked)
do $p$
declare d text; n text;
begin
  d := pg_get_functiondef('public.chat_messages(uuid, timestamptz)'::regprocedure);
  if position('chat_blocks' in d) > 0 then raise notice 'chat_messages already hides blocked people';
  else
    n := replace(d, 'where chat_id = p_chat and (p_after is null or created_at > p_after)',
      'where chat_id = p_chat and (p_after is null or created_at > p_after) and not exists (select 1 from public.chat_blocks b where b.user_id = auth.uid() and (b.blocked_staff = chat_messages.sender_staff_id or b.blocked_customer = chat_messages.sender_customer_id))');
    if n = d then raise exception 'chat_messages patch did not apply'; end if;
    execute n;
  end if;
  if to_regprocedure('public.chat_push_targets(uuid)') is null then raise notice 'no chat_push_targets here, skipped';
  else
    d := pg_get_functiondef('public.chat_push_targets(uuid)'::regprocedure);
    if position('chat_blocks' in d) > 0 then raise notice 'chat_push_targets already skips blocked people';
    else
      n := replace(d, ') q where u is not null;',
        ') q where u is not null and not exists (select 1 from public.chat_blocks b where b.user_id = q.u and (b.blocked_staff = m.sender_staff_id or b.blocked_customer = m.sender_customer_id));');
      if n = d then raise exception 'chat_push_targets patch did not apply'; end if;
      execute n;
    end if;
  end if;
end $p$;
notify pgrst, 'reload schema';
