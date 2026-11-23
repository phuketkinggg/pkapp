-- Who sees Instagram, Facebook and WhatsApp messages (feature social_who).
-- By default the front desk and managers see them. The owner (or a manager, when no owner is set) can choose
-- the people for each one, for example Instagram only for the owner. Then only those people see those chats
-- in Messages, can reply, and get the phone notice. Settings: app_settings social_inbox = {"ig":[staff ids], "fb":[...], "wa":[...]}.

create or replace function private.social_who(p_kind text) returns jsonb language sql stable security definer set search_path = '' as $f$
  select case when p_kind in ('fb','ig','wa') and private.feature('social_who', true) then
    nullif(coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'social_inbox') -> p_kind, '[]'::jsonb), '[]'::jsonb) end
$f$;

-- false when the chat is a social chat kept for chosen people, and I am not one of them
create or replace function private.social_chat_ok(p_chat uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select not exists (select 1 from public.chats c where c.id = p_chat and private.social_who(c.kind) is not null
    and not coalesce(private.social_who(c.kind) ? private.my_staff_id()::text, false))
$f$;

-- true when I am one of the chosen people for this social chat
create or replace function private.social_member(p_chat uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select exists (select 1 from public.chats c where c.id = p_chat and coalesce(private.social_who(c.kind) ? private.my_staff_id()::text, false))
$f$;
revoke all on function private.social_who(text), private.social_chat_ok(uuid), private.social_member(uuid) from public, anon, authenticated;

create or replace function private.social_who_boss() returns boolean language sql stable security definer set search_path = '' as $f$
  select case when to_regprocedure('private.biz_owner_id()') is not null and private.biz_owner_id() is not null
    then private.my_staff_id() = private.biz_owner_id() else coalesce(private.staff_role() = 'manager', false) end
$f$;

create or replace function public.social_inbox_get() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if not coalesce(private.staff_role() = 'manager', false) then raise exception 'Only a manager can see this.'; end if;
  return jsonb_build_object('can_edit', private.social_who_boss(),
    'who', coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'social_inbox'), '{}'::jsonb),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', s.role) order by s.name) from public.staff s where s.active), '[]'::jsonb));
end $f$;

create or replace function public.social_inbox_set(p jsonb) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare out jsonb := '{}'::jsonb; k text; ids jsonb;
begin
  if not private.social_who_boss() then raise exception 'Only the owner can choose who sees these messages.'; end if;
  foreach k in array array['ig','fb','wa'] loop
    select coalesce(jsonb_agg(s.id::text), '[]'::jsonb) into ids from public.staff s
      where s.active and s.id::text in (select jsonb_array_elements_text(case when jsonb_typeof(p->k) = 'array' then p->k else '[]'::jsonb end));
    if jsonb_array_length(ids) > 0 then out := out || jsonb_build_object(k, ids); end if;
  end loop;
  insert into public.app_settings(key, value) values ('social_inbox', out::text) on conflict (key) do update set value = excluded.value;
  return out;
end $f$;
revoke all on function public.social_inbox_get(), public.social_inbox_set(jsonb) from public, anon;
grant execute on function public.social_inbox_get(), public.social_inbox_set(jsonb) to authenticated;

-- phone notices for a new message: only the chosen people when the chat is kept for them
drop function if exists public.web_push_targets();
create or replace function public.web_push_targets(p_chat uuid default null) returns jsonb language sql stable security definer set search_path = '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth)), '[]'::jsonb)
  from public.push_subs p join public.staff s on s.id = p.staff_id
  where p.off_at is null and coalesce(s.active, true)
    and case when (select private.social_who(c.kind) from public.chats c where c.id = p_chat) is not null
      then (select private.social_who(c.kind) from public.chats c where c.id = p_chat) ? s.id::text
      else s.role in ('manager','admin','front_desk','resort') end
$f$;
revoke all on function public.web_push_targets(uuid) from public, anon, authenticated;
grant execute on function public.web_push_targets(uuid) to service_role;

do $p$
declare d text; n text;
begin
  -- who can open a chat
  d := pg_get_functiondef('private.chat_can(uuid)'::regprocedure);
  if position('social_chat_ok' in d) = 0 then
    n := replace(d, 'select p_chat is not null and exists (select 1 from public.chats c0 where c0.id = p_chat) and (',
      'select p_chat is not null and exists (select 1 from public.chats c0 where c0.id = p_chat) and private.social_chat_ok(p_chat) and (private.social_member(p_chat) or ');
    if n = d then raise notice 'social_inbox_who: chat_can is different, skipped'; else execute n; end if;
  end if;
  -- the chat list: chosen people count the chat as theirs (unread, notices)
  d := pg_get_functiondef('public.chat_list()'::regprocedure);
  if position('social_member' in d) = 0 then
    n := replace(d, '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'',''wa'') and desk)',
      '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'',''wa'') and desk and private.social_chat_ok(c.id)) or private.social_member(c.id)');
    if n = d then n := replace(d, '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'') and desk)',
      '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'') and desk and private.social_chat_ok(c.id)) or private.social_member(c.id)'); end if;
    if n = d then raise notice 'social_inbox_who: chat_list is different, skipped'; else execute n; end if;
  end if;
  -- AI reply drafts: only for people who can open that chat (before, any staff saw every draft)
  if to_regprocedure('public.ai_drafts_waiting(uuid)') is not null then
    d := pg_get_functiondef('public.ai_drafts_waiting(uuid)'::regprocedure);
    if position('chat_can' in d) = 0 then
      n := replace(d, 'where d.status = ''waiting'' and (p_chat is null or d.chat_id = p_chat)', 'where d.status = ''waiting'' and private.chat_can(d.chat_id) and (p_chat is null or d.chat_id = p_chat)');
      if n = d then raise notice 'social_inbox_who: ai_drafts_waiting is different, skipped'; else execute n; end if;
    end if;
  end if;
  if to_regprocedure('public.ai_draft_set(uuid,text)') is not null then
    d := pg_get_functiondef('public.ai_draft_set(uuid,text)'::regprocedure);
    if position('chat_can' in d) = 0 then
      n := replace(d, 'where id = p_id and status = ''waiting'';', 'where id = p_id and status = ''waiting'' and private.chat_can(chat_id);');
      if n = d then raise notice 'social_inbox_who: ai_draft_set is different, skipped'; else execute n; end if;
    end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
