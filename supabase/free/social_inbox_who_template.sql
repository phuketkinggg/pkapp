delete from mf.template where name like 'social_inbox_who:%';
insert into mf.template (ord, phase, kind, name, sql) values (404701, 4, 'patch', 'social_inbox_who:404701', $TPL$create or replace function __Q__.social_who(p_kind text) returns jsonb language sql stable security definer set search_path = '' as $f$
  select case when p_kind in ('fb','ig','wa') and __Q__.feature('social_who', true) then
    nullif(coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'social_inbox') -> p_kind, '[]'::jsonb), '[]'::jsonb) end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404702, 4, 'patch', 'social_inbox_who:404702', $TPL$create or replace function __Q__.social_chat_ok(p_chat uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select not exists (select 1 from __P__.chats c where c.id = p_chat and __Q__.social_who(c.kind) is not null
    and not coalesce(__Q__.social_who(c.kind) ? __Q__.my_staff_id()::text, false))
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404703, 4, 'patch', 'social_inbox_who:404703', $TPL$create or replace function __Q__.social_member(p_chat uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select exists (select 1 from __P__.chats c where c.id = p_chat and coalesce(__Q__.social_who(c.kind) ? __Q__.my_staff_id()::text, false))
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198801, 11, 'patch', 'social_inbox_who:1198801', $TPL$revoke all on function __Q__.social_who(text), __Q__.social_chat_ok(uuid), __Q__.social_member(uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404704, 4, 'patch', 'social_inbox_who:404704', $TPL$create or replace function __Q__.social_who_boss() returns boolean language sql stable security definer set search_path = '' as $f$
  select case when to_regprocedure('__Q__.biz_owner_id()') is not null and __Q__.biz_owner_id() is not null
    then __Q__.my_staff_id() = __Q__.biz_owner_id() else coalesce(__Q__.staff_role() = 'manager', false) end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404705, 4, 'patch', 'social_inbox_who:404705', $TPL$create or replace function __P__.social_inbox_get() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if not coalesce(__Q__.staff_role() = 'manager', false) then raise exception 'Only a manager can see this.'; end if;
  return jsonb_build_object('can_edit', __Q__.social_who_boss(),
    'who', coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'social_inbox'), '{}'::jsonb),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', s.role) order by s.name) from __P__.staff s where s.active), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404706, 4, 'patch', 'social_inbox_who:404706', $TPL$create or replace function __P__.social_inbox_set(p jsonb) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare out jsonb := '{}'::jsonb; k text; ids jsonb;
begin
  if not __Q__.social_who_boss() then raise exception 'Only the owner can choose who sees these messages.'; end if;
  foreach k in array array['ig','fb','wa'] loop
    select coalesce(jsonb_agg(s.id::text), '[]'::jsonb) into ids from __P__.staff s
      where s.active and s.id::text in (select jsonb_array_elements_text(case when jsonb_typeof(p->k) = 'array' then p->k else '[]'::jsonb end));
    if jsonb_array_length(ids) > 0 then out := out || jsonb_build_object(k, ids); end if;
  end loop;
  insert into __P__.app_settings(key, value) values ('social_inbox', out::text) on conflict (key) do update set value = excluded.value;
  return out;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198802, 11, 'patch', 'social_inbox_who:1198802', $TPL$revoke all on function __P__.social_inbox_get(), __P__.social_inbox_set(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198803, 11, 'patch', 'social_inbox_who:1198803', $TPL$grant execute on function __P__.social_inbox_get(), __P__.social_inbox_set(jsonb) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003301, 10, 'patch', 'social_inbox_who:1003301', $TPL$drop function if exists __P__.web_push_targets();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404707, 4, 'patch', 'social_inbox_who:404707', $TPL$create or replace function __P__.web_push_targets(p_chat uuid default null) returns jsonb language sql stable security definer set search_path = '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth)), '[]'::jsonb)
  from __P__.push_subs p join __P__.staff s on s.id = p.staff_id
  where p.off_at is null and coalesce(s.active, true)
    and case when (select __Q__.social_who(c.kind) from __P__.chats c where c.id = p_chat) is not null
      then (select __Q__.social_who(c.kind) from __P__.chats c where c.id = p_chat) ? s.id::text
      else s.role in ('manager','admin','front_desk','resort') end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198804, 11, 'patch', 'social_inbox_who:1198804', $TPL$revoke all on function __P__.web_push_targets(uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198805, 11, 'patch', 'social_inbox_who:1198805', $TPL$grant execute on function __P__.web_push_targets(uuid) to service_role;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003302, 10, 'patch', 'social_inbox_who:1003302', $TPL$do $p$
declare d text; n text;
begin
  -- who can open a chat
  d := pg_get_functiondef('__Q__.chat_can(uuid)'::regprocedure);
  if position('social_chat_ok' in d) = 0 then
    n := replace(d, 'select p_chat is not null and exists (select 1 from __P__.chats c0 where c0.id = p_chat) and (',
      'select p_chat is not null and exists (select 1 from __P__.chats c0 where c0.id = p_chat) and __Q__.social_chat_ok(p_chat) and (__Q__.social_member(p_chat) or ');
    if n = d then raise notice 'social_inbox_who: chat_can is different, skipped'; else execute n; end if;
  end if;
  -- the chat list: chosen people count the chat as theirs (unread, notices)
  d := pg_get_functiondef('__P__.chat_list()'::regprocedure);
  if position('social_member' in d) = 0 then
    n := replace(d, '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'',''wa'') and desk)',
      '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'',''wa'') and desk and __Q__.social_chat_ok(c.id)) or __Q__.social_member(c.id)');
    if n = d then n := replace(d, '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'') and desk)',
      '''in_chat'', (c.kind in (''desk'',''web'',''fb'',''ig'') and desk and __Q__.social_chat_ok(c.id)) or __Q__.social_member(c.id)'); end if;
    if n = d then raise notice 'social_inbox_who: chat_list is different, skipped'; else execute n; end if;
  end if;
  -- AI reply drafts: only for people who can open that chat (before, any staff saw every draft)
  if to_regprocedure('__P__.ai_drafts_waiting(uuid)') is not null then
    d := pg_get_functiondef('__P__.ai_drafts_waiting(uuid)'::regprocedure);
    if position('chat_can' in d) = 0 then
      n := replace(d, 'where d.status = ''waiting'' and (p_chat is null or d.chat_id = p_chat)', 'where d.status = ''waiting'' and __Q__.chat_can(d.chat_id) and (p_chat is null or d.chat_id = p_chat)');
      if n = d then raise notice 'social_inbox_who: ai_drafts_waiting is different, skipped'; else execute n; end if;
    end if;
  end if;
  if to_regprocedure('__P__.ai_draft_set(uuid,text)') is not null then
    d := pg_get_functiondef('__P__.ai_draft_set(uuid,text)'::regprocedure);
    if position('chat_can' in d) = 0 then
      n := replace(d, 'where id = p_id and status = ''waiting'';', 'where id = p_id and status = ''waiting'' and __Q__.chat_can(chat_id);');
      if n = d then raise notice 'social_inbox_who: ai_draft_set is different, skipped'; else execute n; end if;
    end if;
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'social_inbox_who:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
