delete from mf.template where name like 'ai_learn:%';
insert into mf.template (ord, phase, kind, name, sql) values (303411, 3, 'patch', 'ai_learn:303411', $TPL$create table if not exists __P__.saved_replies (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 80),
  body text not null check (char_length(body) between 1 and 2000),
  tags text[],
  created_by uuid references __P__.staff (id) on delete set null,
  uses integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303412, 3, 'patch', 'ai_learn:303412', $TPL$alter table __P__.saved_replies enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197511, 11, 'patch', 'ai_learn:1197511', $TPL$revoke all on __P__.saved_replies from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303413, 3, 'patch', 'ai_learn:303413', $TPL$create table if not exists __P__.ai_drafts (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references __P__.chats (id) on delete cascade,
  body text not null,
  topic text,
  status text not null default 'waiting' check (status in ('waiting','sent','dismissed','old')),
  decided_by uuid references __P__.staff (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002111, 10, 'patch', 'ai_learn:1002111', $TPL$create index if not exists ai_drafts_chat on __P__.ai_drafts (chat_id) where status = 'waiting';$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303414, 3, 'patch', 'ai_learn:303414', $TPL$alter table __P__.ai_drafts enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197512, 11, 'patch', 'ai_learn:1197512', $TPL$revoke all on __P__.ai_drafts from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303415, 3, 'patch', 'ai_learn:303415', $TPL$create table if not exists __P__.ai_learn_msgs (
  id bigint generated always as identity primary key,
  source text not null check (source in ('ig','fb','wa_export')),
  chat_key text not null,
  at timestamptz not null,
  from_us boolean not null,
  body text not null,
  hash text not null unique
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303416, 3, 'patch', 'ai_learn:303416', $TPL$alter table __P__.ai_learn_msgs enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197513, 11, 'patch', 'ai_learn:1197513', $TPL$revoke all on __P__.ai_learn_msgs from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403511, 4, 'patch', 'ai_learn:403511', $TPL$create or replace function __Q__.ai_learned() returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('mode', 'auto', 'style', '', 'faqs', '[]'::jsonb, 'auto_topics', '[]'::jsonb)
    || coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'ai_learned'), '{}'::jsonb)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403512, 4, 'patch', 'ai_learn:403512', $TPL$create or replace function __P__.ai_learn_get() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return __Q__.ai_learned() || jsonb_build_object(
    'app_msgs', (select count(*) from __P__.chat_messages m join __P__.chats c on c.id = m.chat_id
                 where c.kind in ('wa','fb','ig','web') and m.created_at > now() - interval '6 months' and coalesce(m.body, '') <> ''),
    'imported', (select jsonb_object_agg(source, n) from (select source, count(*) n from __P__.ai_learn_msgs where at > now() - interval '6 months' group by 1) x),
    'status', (select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'ai_learn_status'));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403513, 4, 'patch', 'ai_learn:403513', $TPL$create or replace function __P__.ai_learn_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare c jsonb := __Q__.ai_learned(); f jsonb;
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  if p ? 'mode' then c := c || jsonb_build_object('mode', case when p->>'mode' in ('auto','approve','mixed') then p->>'mode' else 'approve' end); end if;
  if p ? 'style' then c := c || jsonb_build_object('style', left(coalesce(p->>'style', ''), 6000)); end if;
  if p ? 'auto_topics' then c := c || jsonb_build_object('auto_topics', coalesce((select jsonb_agg(distinct t) from jsonb_array_elements_text(p->'auto_topics') t where t ~ '^[a-z_]{2,20}$'), '[]'::jsonb)); end if;
  if p ? 'faqs' then
    select coalesce(jsonb_agg(jsonb_build_object('id', coalesce(nullif(x->>'id', ''), substr(md5(random()::text), 1, 8)), 'q', left(x->>'q', 300), 'a', left(x->>'a', 1500),
      'topic', coalesce(nullif(x->>'topic', ''), 'other'), 'ok', coalesce((x->>'ok')::boolean, false))), '[]'::jsonb)
      into f from jsonb_array_elements(p->'faqs') x where coalesce(x->>'q', '') <> '' and coalesce(x->>'a', '') <> '';
    c := c || jsonb_build_object('faqs', f);
  end if;
  insert into __P__.app_settings(key, value) values ('ai_learned', c::text) on conflict (key) do update set value = excluded.value;
  return c;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403514, 4, 'patch', 'ai_learn:403514', $TPL$create or replace function __P__.ai_learn_import(p_rows jsonb, p_source text) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare n int := 0; r jsonb; t timestamptz; h text;
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if p_source not in ('wa_export','ig','fb') then raise exception 'Unknown source.'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 50000 then raise exception 'The file has too many lines.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    begin t := (r->>'at')::timestamptz; exception when others then continue; end;
    if t < now() - interval '200 days' or coalesce(btrim(r->>'body'), '') = '' then continue; end if;
    h := md5(p_source || '|' || coalesce(r->>'chat', '') || '|' || t::text || '|' || (r->>'body'));
    insert into __P__.ai_learn_msgs (source, chat_key, at, from_us, body, hash)
      values (p_source, left(coalesce(r->>'chat', 'chat'), 120), t, coalesce((r->>'us')::boolean, false), left(r->>'body', 3000), h)
      on conflict (hash) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return jsonb_build_object('added', n);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403515, 4, 'patch', 'ai_learn:403515', $TPL$create or replace function __P__.ai_learn_import_svc(p_rows jsonb, p_source text) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare n int := 0; r jsonb; t timestamptz;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    begin t := (r->>'at')::timestamptz; exception when others then continue; end;
    if coalesce(btrim(r->>'body'), '') = '' then continue; end if;
    insert into __P__.ai_learn_msgs (source, chat_key, at, from_us, body, hash)
      values (p_source, left(coalesce(r->>'chat', 'chat'), 120), t, coalesce((r->>'us')::boolean, false), left(r->>'body', 3000),
        md5(p_source || '|' || coalesce(r->>'chat', '') || '|' || t::text || '|' || (r->>'body')))
      on conflict (hash) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return jsonb_build_object('added', n);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197514, 11, 'patch', 'ai_learn:1197514', $TPL$revoke all on function __P__.ai_learn_import_svc(jsonb, text) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403516, 4, 'patch', 'ai_learn:403516', $TPL$create or replace function __P__.ai_learn_corpus() returns jsonb language sql stable security definer set search_path to '' as $f$
  with app as (
    select c.id::text as chat, c.kind as src, m.created_at as at, not m.from_visitor as us, m.via = 'ai' as ai, m.body
    from __P__.chat_messages m join __P__.chats c on c.id = m.chat_id
    where c.kind in ('wa','fb','ig','web') and m.created_at > now() - interval '6 months' and coalesce(m.body, '') <> ''
  ), first_app as (select min(at) as t from app),
  imp as (
    select l.source || ':' || l.chat_key as chat, l.source as src, l.at, l.from_us as us, false as ai, l.body
    from __P__.ai_learn_msgs l
    where l.at > now() - interval '6 months' and (l.source = 'wa_export' or l.at < coalesce((select t from first_app), now()))
  ), alll as (select * from app union all select * from imp)
  select coalesce(jsonb_agg(jsonb_build_object('chat', chat, 'src', src, 'lines', lines) order by last_at desc), '[]'::jsonb)
  from (select chat, max(src) as src, max(at) as last_at,
          string_agg(case when us then (case when ai then 'AI: ' else 'TEAM: ' end) else 'CUSTOMER: ' end || replace(left(body, 800), E'\n', ' '), E'\n' order by at) as lines
        from alll group by chat having bool_or(us and not ai) and bool_or(not us)) x
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197515, 11, 'patch', 'ai_learn:1197515', $TPL$revoke all on function __P__.ai_learn_corpus() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403517, 4, 'patch', 'ai_learn:403517', $TPL$create or replace function __P__.ai_learn_status(p jsonb) returns void language sql security definer set search_path to '' as $f$
  insert into __P__.app_settings(key, value) values ('ai_learn_status', (p || jsonb_build_object('at', now()))::text)
  on conflict (key) do update set value = excluded.value
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197516, 11, 'patch', 'ai_learn:1197516', $TPL$revoke all on function __P__.ai_learn_status(jsonb) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403518, 4, 'patch', 'ai_learn:403518', $TPL$create or replace function __P__.ai_learn_ctx() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when __Q__.feature('ai_learn', true) then
    jsonb_build_object('mode', l->>'mode', 'style', l->>'style', 'auto_topics', l->'auto_topics',
      'faqs', coalesce((select jsonb_agg(jsonb_build_object('q', x->>'q', 'a', x->>'a', 'topic', x->>'topic')) from jsonb_array_elements(l->'faqs') x where (x->>'ok')::boolean), '[]'::jsonb),
      'saved', case when __Q__.feature('saved_replies', true) then coalesce((select jsonb_agg(jsonb_build_object('title', s.title, 'body', s.body) order by s.uses desc) from (select * from __P__.saved_replies order by uses desc limit 40) s), '[]'::jsonb) else '[]'::jsonb end)
  else jsonb_build_object('mode', 'auto', 'style', '', 'faqs', '[]'::jsonb, 'auto_topics', '[]'::jsonb, 'saved', '[]'::jsonb) end
  from (select __Q__.ai_learned() l) z
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197517, 11, 'patch', 'ai_learn:1197517', $TPL$revoke all on function __P__.ai_learn_ctx() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403519, 4, 'patch', 'ai_learn:403519', $TPL$create or replace function __P__.ai_draft_add(p_chat uuid, p_body text, p_topic text) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v uuid;
begin
  update __P__.ai_drafts set status = 'old' where chat_id = p_chat and status = 'waiting';
  insert into __P__.ai_drafts (chat_id, body, topic) values (p_chat, left(p_body, 4000), left(p_topic, 30)) returning id into v;
  return v;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197518, 11, 'patch', 'ai_learn:1197518', $TPL$revoke all on function __P__.ai_draft_add(uuid, text, text) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403520, 4, 'patch', 'ai_learn:403520', $TPL$create or replace function __P__.ai_drafts_waiting(p_chat uuid default null) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if __Q__.my_staff_id() is null then raise exception 'Only the team can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'chat_id', d.chat_id, 'body', d.body, 'topic', d.topic, 'at', d.created_at,
      'who', coalesce(c.title, c.visitor_name, 'Customer'), 'kind', c.kind) order by d.created_at desc)
    from __P__.ai_drafts d join __P__.chats c on c.id = d.chat_id
    where d.status = 'waiting' and (p_chat is null or d.chat_id = p_chat) and d.created_at > now() - interval '7 days'), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403521, 4, 'patch', 'ai_learn:403521', $TPL$create or replace function __P__.ai_draft_set(p_id uuid, p_status text) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if __Q__.my_staff_id() is null then raise exception 'Only the team can do this.'; end if;
  if p_status not in ('sent','dismissed') then raise exception 'Unknown choice.'; end if;
  update __P__.ai_drafts set status = p_status, decided_by = __Q__.my_staff_id(), decided_at = now() where id = p_id and status = 'waiting';
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403522, 4, 'patch', 'ai_learn:403522', $TPL$create or replace function __P__.saved_replies_list() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if __Q__.my_staff_id() is null then raise exception 'Only the team can see this.'; end if;
  if not __Q__.feature('saved_replies', true) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'body', s.body, 'tags', s.tags, 'uses', s.uses,
      'mine', s.created_by = __Q__.my_staff_id()) order by s.uses desc, s.title) from __P__.saved_replies s), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403523, 4, 'patch', 'ai_learn:403523', $TPL$create or replace function __P__.saved_reply_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v uuid := nullif(p->>'id', '')::uuid; me uuid := __Q__.my_staff_id(); s __P__.saved_replies;
begin
  if me is null then raise exception 'Only the team can do this.'; end if;
  if not __Q__.feature('saved_replies', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if coalesce(btrim(p->>'title'), '') = '' or coalesce(btrim(p->>'body'), '') = '' then raise exception 'Give it a short name and the reply.'; end if;
  if v is not null then
    select * into s from __P__.saved_replies where id = v;
    if s.id is null then raise exception 'That saved reply is gone.'; end if;
    if s.created_by is distinct from me and coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager or the person who saved it can change it.'; end if;
    if coalesce((p->>'delete')::boolean, false) then delete from __P__.saved_replies where id = v; return v; end if;
    update __P__.saved_replies set title = left(btrim(p->>'title'), 80), body = left(btrim(p->>'body'), 2000), updated_at = now() where id = v;
    return v;
  end if;
  insert into __P__.saved_replies (title, body, created_by) values (left(btrim(p->>'title'), 80), left(btrim(p->>'body'), 2000), me) returning id into v;
  return v;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403524, 4, 'patch', 'ai_learn:403524', $TPL$create or replace function __P__.saved_reply_used(p_id uuid) returns void language sql security definer set search_path to '' as $f$
  update __P__.saved_replies set uses = uses + 1 where id = p_id and __Q__.my_staff_id() is not null
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197519, 11, 'patch', 'ai_learn:1197519', $TPL$revoke all on function __P__.ai_learn_get() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197520, 11, 'patch', 'ai_learn:1197520', $TPL$revoke all on function __P__.ai_learn_save(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197521, 11, 'patch', 'ai_learn:1197521', $TPL$revoke all on function __P__.ai_learn_import(jsonb, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197522, 11, 'patch', 'ai_learn:1197522', $TPL$revoke all on function __P__.ai_drafts_waiting(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197523, 11, 'patch', 'ai_learn:1197523', $TPL$revoke all on function __P__.ai_draft_set(uuid, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197524, 11, 'patch', 'ai_learn:1197524', $TPL$revoke all on function __P__.saved_replies_list() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197525, 11, 'patch', 'ai_learn:1197525', $TPL$revoke all on function __P__.saved_reply_save(jsonb) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197526, 11, 'patch', 'ai_learn:1197526', $TPL$revoke all on function __P__.saved_reply_used(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197527, 11, 'patch', 'ai_learn:1197527', $TPL$grant execute on function __P__.ai_learn_get() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197528, 11, 'patch', 'ai_learn:1197528', $TPL$grant execute on function __P__.ai_learn_save(jsonb) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197529, 11, 'patch', 'ai_learn:1197529', $TPL$grant execute on function __P__.ai_learn_import(jsonb, text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197530, 11, 'patch', 'ai_learn:1197530', $TPL$grant execute on function __P__.ai_drafts_waiting(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197531, 11, 'patch', 'ai_learn:1197531', $TPL$grant execute on function __P__.ai_draft_set(uuid, text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197532, 11, 'patch', 'ai_learn:1197532', $TPL$grant execute on function __P__.saved_replies_list() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197533, 11, 'patch', 'ai_learn:1197533', $TPL$grant execute on function __P__.saved_reply_save(jsonb) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197534, 11, 'patch', 'ai_learn:1197534', $TPL$grant execute on function __P__.saved_reply_used(uuid) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'ai_learn:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
