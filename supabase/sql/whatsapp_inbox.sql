-- WhatsApp in the app's Messages (feature whatsapp_inbox), next to website chat, Facebook and Instagram,
-- and an AI that answers customers straight away (feature ai_reply), from the business's own facts.
-- Incoming WhatsApp: the "meta" edge function (Meta webhook, object whatsapp_business_account) calls public.meta_incoming with kind 'wa'.
-- Outgoing: a staff reply in a WhatsApp chat is marked "sending" and handed to the meta function, like Facebook and Instagram.
-- Needs meta_inbox.sql first. Where it is missing (an older demo) this file skips the chat parts cleanly.

-- ---------- WhatsApp as a chat kind ----------
do $p$
declare d text;
begin
  if to_regprocedure('public.meta_incoming(jsonb)') is null then raise notice 'no meta inbox here, WhatsApp chat parts skipped'; return; end if;
  select pg_get_constraintdef(oid) into d from pg_constraint where conname = 'chats_kind_check2' and conrelid = 'public.chats'::regclass;
  if d is null or position('''wa''' in d) = 0 then
    alter table public.chats drop constraint if exists chats_kind_check2;
    alter table public.chats add constraint chats_kind_check2 check (kind = any (array['desk','coach','staff','group','web','fb','ig','wa']));
  end if;
end $p$;

-- every place that treats Facebook and Instagram chats as desk chats now does the same for WhatsApp
do $p$
declare f text; d text; n text;
begin
  if to_regprocedure('public.meta_incoming(jsonb)') is null then return; end if;
  foreach f in array array['private.chat_can(uuid)','public.chat_list()','private.meta_out_mark()','public.chat_push_targets(uuid)','public.meta_incoming(jsonb)'] loop
    if to_regprocedure(f) is null then raise notice '% missing, skipped', f; continue; end if;
    d := pg_get_functiondef(f::regprocedure);
    if position('''wa''' in d) > 0 then raise notice '% already has WhatsApp', f; continue; end if;
    n := replace(d, '''fb'',''ig'')', '''fb'',''ig'',''wa'')');
    if n = d then raise notice '% has no Facebook and Instagram list, skipped', f; continue; end if;
    if f = 'public.chat_list()' then
      n := replace(n, 'when c.kind = ''desk'' then case', 'when c.kind = ''wa'' then ''WhatsApp: '' || coalesce(nullif(c.visitor_name,''''), c.visitor_contact, ''WhatsApp user'')
        when c.kind = ''desk'' then case');
      n := replace(n, 'when mm.via = ''meta'' then ''Team''', 'when mm.via = ''meta'' then ''Team'' when mm.via = ''ai'' then ''AI reply''');
    end if;
    if f = 'public.meta_incoming(jsonb)' then
      -- a WhatsApp chat keeps the phone number as the contact
      n := replace(n, '  insert into public.chat_messages(chat_id, body, created_at, from_visitor, ext_id, via, media, send_status)',
        '  if k = ''wa'' then update public.chats set visitor_contact = coalesce(nullif(visitor_contact,''''), ''+'' || sid) where id = cid; end if;
  insert into public.chat_messages(chat_id, body, created_at, from_visitor, ext_id, via, media, send_status)');
    end if;
    execute n;
    if position('''wa''' in pg_get_functiondef(f::regprocedure)) = 0 then raise exception '% WhatsApp patch did not apply', f; end if;
  end loop;
end $p$;

-- who wrote a message: AI replies and replies sent from the WhatsApp app on the phone get their own label
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.chat_messages(uuid,timestamp with time zone)') is null then return; end if;
  d := pg_get_functiondef('public.chat_messages(uuid,timestamp with time zone)'::regprocedure);
  if position('AI reply' in d) > 0 then raise notice 'chat_messages already patched'; return; end if;
  if position('when m.via = ''meta'' then ''Team (in the Meta app)''' in d) = 0 then raise notice 'chat_messages: older version, skipped'; return; end if;
  n := replace(d, 'when m.via = ''meta'' then ''Team (in the Meta app)''',
    'when m.via = ''ai'' then ''AI reply'' when m.via = ''meta'' then case when (select kind from public.chats where id = p_chat) = ''wa'' then ''Team (WhatsApp app)'' else ''Team (in the Meta app)'' end');
  n := replace(n, '''staff'', m.sender_staff_id is not null or m.via = ''meta''', '''staff'', m.sender_staff_id is not null or m.via in (''meta'',''ai'')');
  execute n;
  if position('AI reply' in pg_get_functiondef('public.chat_messages(uuid,timestamp with time zone)'::regprocedure)) = 0 then raise exception 'chat_messages patch did not apply'; end if;
end $p$;

-- ---------- the WhatsApp connection ----------
-- the number, its WhatsApp ids and (when connected with the Meta sign in) the access token. Kept in the private schema, never shown in the app.
create table if not exists private.wa_link (
  id boolean primary key default true check (id),
  phone_id text, waba_id text, number text, name text, token text, coexist boolean not null default false,
  connected_at timestamptz, synced jsonb not null default '{}'::jsonb
);
revoke all on private.wa_link from public, anon, authenticated;

-- for the meta function only
create or replace function public.wa_get() returns jsonb language sql stable security definer set search_path='' as $f$
  select coalesce((select jsonb_build_object('phone_id', phone_id, 'waba_id', waba_id, 'number', number, 'name', name, 'token', token, 'coexist', coexist, 'synced', synced) from private.wa_link), '{}'::jsonb)
$f$;
create or replace function public.wa_set(p jsonb) returns void language plpgsql security definer set search_path='' as $f$
begin
  insert into private.wa_link(id) values (true) on conflict (id) do nothing;
  update private.wa_link set
    phone_id = case when p ? 'phone_id' then nullif(p->>'phone_id','') else phone_id end,
    waba_id = case when p ? 'waba_id' then nullif(p->>'waba_id','') else waba_id end,
    number = case when p ? 'number' then nullif(p->>'number','') else number end,
    name = case when p ? 'name' then nullif(p->>'name','') else name end,
    token = case when p ? 'token' then nullif(p->>'token','') else token end,
    coexist = case when p ? 'coexist' then coalesce((p->>'coexist')::boolean, false) else coexist end,
    synced = case when p ? 'synced' then synced || coalesce(p->'synced','{}'::jsonb) else synced end,
    connected_at = case when p ? 'phone_id' and nullif(p->>'phone_id','') is not null then now() when p ? 'phone_id' then null else connected_at end;
end $f$;
revoke all on function public.wa_get() from public, anon, authenticated;
revoke all on function public.wa_set(jsonb) from public, anon, authenticated;
grant execute on function public.wa_get() to service_role;
grant execute on function public.wa_set(jsonb) to service_role;

-- what the app shows: connected or not, the number (no token), and the Meta app and sign in configuration used to connect
create or replace function public.wa_status() returns jsonb language plpgsql stable security definer set search_path='' as $f$
begin
  if not private.is_desk() then raise exception 'Only the desk can see this.'; end if;
  return coalesce((select jsonb_build_object('connected', phone_id is not null, 'number', number, 'name', name, 'coexist', coexist, 'at', connected_at) from private.wa_link), jsonb_build_object('connected', false))
    || jsonb_build_object('meta', coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'wa_meta'), '{}'::jsonb));
end $f$;
grant execute on function public.wa_status() to authenticated;

-- the Meta app ID and the WhatsApp sign in configuration ID (not secret: they are shown in Meta's own sign in window)
create or replace function public.wa_meta_save(p_app_id text, p_config_id text) returns void language plpgsql security definer set search_path='' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can connect WhatsApp.'; end if;
  if coalesce(p_app_id,'') !~ '^\d{6,}$' then raise exception 'The Meta app ID is a long number.'; end if;
  if coalesce(p_config_id,'') !~ '^\d{6,}$' then raise exception 'The configuration ID is a long number.'; end if;
  insert into public.app_settings(key, value) values ('wa_meta', jsonb_build_object('app_id', p_app_id, 'config_id', p_config_id)::text)
    on conflict (key) do update set value = excluded.value;
end $f$;
grant execute on function public.wa_meta_save(text, text) to authenticated;

-- ---------- AI replies ----------
-- settings (app_settings ai_reply): on, channels, when (always or away: only when website chat shows Away), pause_h (quiet this many hours after a staff reply), notes (extra facts from the owner)
create or replace function private.ai_reply_cfg() returns jsonb language sql stable security definer set search_path='' as $f$
  select jsonb_build_object('on', false, 'channels', jsonb_build_array('wa','fb','ig'), 'when', 'always', 'pause_h', 12, 'notes', '', 'site', '')
    || coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'ai_reply'), '{}'::jsonb)
$f$;

create or replace function public.ai_reply_settings() returns jsonb language plpgsql stable security definer set search_path='' as $f$
begin
  if not private.is_desk() then raise exception 'Only the desk can see this.'; end if;
  return private.ai_reply_cfg();
end $f$;
grant execute on function public.ai_reply_settings() to authenticated;

create or replace function public.ai_reply_save(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare c jsonb; ch jsonb;
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change the AI replies.'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into ch from jsonb_array_elements_text(coalesce(p->'channels', '[]'::jsonb)) x where x in ('wa','fb','ig');
  c := jsonb_build_object('on', coalesce((p->>'on')::boolean, false), 'channels', ch,
    'when', case when p->>'when' = 'away' then 'away' else 'always' end,
    'pause_h', least(72, greatest(0, coalesce(nullif(p->>'pause_h','')::int, 12))),
    'notes', left(coalesce(p->>'notes',''), 4000),
    'site', case when coalesce(p->>'site','') ~ '^https://[^\s/]+\.[^\s]+$' then p->>'site' else '' end);
  insert into public.app_settings(key, value) values ('ai_reply', c::text) on conflict (key) do update set value = excluded.value;
  return c;
end $f$;
grant execute on function public.ai_reply_save(jsonb) to authenticated;

-- everything the AI needs to answer one chat, for the meta function only:
-- the settings, whether it should answer now, the conversation, and the business facts kept in the app
create or replace function public.ai_reply_ctx(p_chat uuid) returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare c public.chats; cfg jsonb := private.ai_reply_cfg(); go boolean; why text := ''; staff_at timestamptz; ai_n int;
begin
  select * into c from public.chats where id = p_chat;
  if c.id is null then return jsonb_build_object('go', false, 'why', 'no chat'); end if;
  select max(created_at) into staff_at from public.chat_messages where chat_id = p_chat and (sender_staff_id is not null or via = 'meta');
  select count(*) into ai_n from public.chat_messages where chat_id = p_chat and via = 'ai' and created_at > now() - interval '1 hour';
  go := private.feature('ai_reply', false) and coalesce((cfg->>'on')::boolean, false) and (cfg->'channels') ? c.kind;
  if not go then why := 'off for this channel';
  elsif cfg->>'when' = 'away' and to_regprocedure('private.web_chat_online()') is not null and private.web_chat_online() then go := false; why := 'the desk is online';
  elsif staff_at is not null and staff_at > now() - make_interval(hours => coalesce((cfg->>'pause_h')::int, 12)) then go := false; why := 'a staff member is in this chat';
  elsif ai_n >= 10 then go := false; why := 'too many AI replies in the last hour';
  end if;
  return jsonb_build_object('go', go, 'why', why, 'kind', c.kind, 'social_id', c.social_id, 'name', c.visitor_name, 'notes', cfg->>'notes', 'site', cfg->>'site',
    'business', private.biz_main(), 'stay', private.biz_stay(),
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('in', m.from_visitor, 'ai', m.via = 'ai', 'body', m.body, 'at', m.created_at) order by m.created_at), '[]'::jsonb)
                 from (select * from public.chat_messages where chat_id = p_chat order by created_at desc limit 20) m),
    'packages', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'thb', p.price_thb, 'local_thb', p.price_local_thb, 'thai_thb', p.price_thai_thb,
                   'who', p.audience, 'days', p.duration_days, 'visits', p.visit_limit, 'covers', p.covers, 'tiers', p.tiers, 'notes', left(coalesce(p.notes,''), 200)) order by p.price_thb), '[]'::jsonb)
                 from public.packages p where p.active),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('day', k.day, 'from', to_char(k.start_time,'HH24:MI'), 'to', to_char(k.end_time,'HH24:MI'), 'title', coalesce(k.title, k.discipline),
                   'off', case when k.off_to >= current_date then concat(k.off_from, ' to ', k.off_to, ' ', coalesce(k.off_note,'')) end) order by k.day, k.start_time), '[]'::jsonb)
                 from public.classes k));
end $f$;
revoke all on function public.ai_reply_ctx(uuid) from public, anon, authenticated;
grant execute on function public.ai_reply_ctx(uuid) to service_role;

-- an AI reply that went out (or did not): saved in the chat like a staff reply, marked as AI
create or replace function public.ai_reply_save_msg(p_chat uuid, p_body text, p_ext text, p_error text) returns uuid language plpgsql security definer set search_path='' as $f$
declare nid uuid;
begin
  insert into public.chat_messages(chat_id, body, created_at, from_visitor, ext_id, via, send_status, send_error)
    values (p_chat, left(p_body, 4000), now(), false, nullif(p_ext,''), 'ai', case when p_error is null then 'sent' else 'failed' end, left(p_error, 300))
    returning id into nid;
  update public.chats set last_at = now() where id = p_chat;
  return nid;
end $f$;
revoke all on function public.ai_reply_save_msg(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.ai_reply_save_msg(uuid, text, text, text) to service_role;

notify pgrst, 'reload schema';
