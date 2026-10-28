-- Report a message (feature: chat_report): anyone in a chat can report a message someone else wrote.
-- The report is kept, and managers and the front desk get a notice that opens the chat.

create table if not exists public.chat_reports (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  message_id uuid not null references public.chat_messages(id) on delete cascade,
  chat_id uuid not null references public.chats(id) on delete cascade,
  reporter_user uuid not null,
  reporter_staff uuid,
  reporter_customer uuid,
  reason text check (char_length(reason) <= 500)
);
create unique index if not exists chat_reports_once on public.chat_reports (message_id, reporter_user);
alter table public.chat_reports enable row level security;
revoke all on public.chat_reports from anon, authenticated;

-- notices about reported messages
do $p$
declare c text; d text;
begin
  select conname, pg_get_constraintdef(oid) into c, d from pg_constraint
    where conrelid = 'public.notices'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' limit 1;
  if c is null then raise notice 'notices has no kind check';
  elsif position('''chat_report''' in d) > 0 then raise notice 'notices already allow chat_report';
  else
    execute format('alter table public.notices drop constraint %I', c);
    execute format('alter table public.notices add constraint %I %s', c,
      regexp_replace(d, '\]\)\)\)$', ', ''chat_report''::text])))'));
    if position('''chat_report''' in pg_get_constraintdef((select oid from pg_constraint where conname = c and conrelid = 'public.notices'::regclass))) = 0 then
      raise exception 'notices kind patch did not apply'; end if;
  end if;
end $p$;

create or replace function public.chat_report(p_message uuid, p_reason text default null) returns void language plpgsql security definer set search_path to '' as $f$
declare m public.chat_messages; c public.chats; me_s uuid := private.my_staff_id(); me_c uuid := private.customer_id();
  who text; rep text; r text := nullif(left(btrim(coalesce(p_reason, '')), 500), ''); cname text;
begin
  if auth.uid() is null or (me_s is null and me_c is null) then raise exception 'Sign in first.'; end if;
  if not private.feature('chat_report', true) then raise exception 'Reporting is turned off.'; end if;
  select * into m from public.chat_messages where id = p_message;
  if m.id is null or not private.chat_can(m.chat_id) then raise exception 'That message was not found.'; end if;
  if (me_s is not null and m.sender_staff_id = me_s) or (me_s is null and m.sender_customer_id = me_c) then raise exception 'That is your own message.'; end if;
  if exists (select 1 from public.chat_reports where message_id = m.id and reporter_user = auth.uid()) then return; end if;
  if (select count(*) from public.chat_reports where reporter_user = auth.uid() and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'You have reported a lot of messages. The team will look at them.'; end if;
  insert into public.chat_reports (message_id, chat_id, reporter_user, reporter_staff, reporter_customer, reason)
    values (m.id, m.chat_id, auth.uid(), me_s, case when me_s is null then me_c end, r);
  select * into c from public.chats where id = m.chat_id;
  who := coalesce(private.chat_who(m.sender_staff_id, m.sender_customer_id), 'Someone');
  rep := coalesce(private.chat_who(me_s, case when me_s is null then me_c end), 'Someone');
  cname := case when c.kind = 'group' then coalesce(c.title, 'a group') else 'a chat' end;
  insert into public.notices (kind, customer_id, ref_id, title, detail)
  values ('chat_report', m.sender_customer_id, m.chat_id, 'Message reported in ' || cname || ': ' || who,
    rep || ' reported: "' || left(m.body, 200) || '"' || coalesce('. Why: ' || r, '') || '. Tap to open the chat.');
end $f$;

revoke all on function public.chat_report(uuid, text) from public, anon;
grant execute on function public.chat_report(uuid, text) to authenticated;
notify pgrst, 'reload schema';
