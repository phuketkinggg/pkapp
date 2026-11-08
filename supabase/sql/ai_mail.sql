-- Ask AI reads the business inbox (feature ai_mail): the same Gmail script that sends booking emails also sends every new
-- inbox email (kind 'inbox'). They are kept 90 days, are not read as bookings, and only the AI (for a manager or admin) reads them.
-- Needs agency_mail.sql. Where it is missing (an older demo) this file skips cleanly.

do $p$
begin
  if to_regclass('private.inbound_mails') is null then raise notice 'no inbound_mails here, skipped'; return; end if;
  alter table private.inbound_mails add column if not exists kind text not null default 'booking';
  alter table private.inbound_mails add column if not exists mail_to text;
  alter table private.inbound_mails add column if not exists msg_id text;
  alter table private.inbound_mails add column if not exists thread_id text;
  alter table private.inbound_mails add column if not exists sent_at timestamptz;
  create unique index if not exists inbound_mails_msg on private.inbound_mails (msg_id) where msg_id is not null;
  create index if not exists inbound_mails_kind_at on private.inbound_mails (kind, received_at desc);
end $p$;

-- keep an email: a booking email (read by the AI as a booking) or an inbox email (kept for Ask AI). The same Gmail message twice is kept once (returns null).
do $p$
begin
  if to_regclass('private.inbound_mails') is null then return; end if;
  execute $f$
create or replace function public.inbound_mail_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $q$
declare v uuid; k text := case when p->>'kind' = 'inbox' then 'inbox' else 'booking' end; at timestamptz;
begin
  begin at := nullif(p->>'at','')::timestamptz; exception when others then at := null; end;
  insert into private.inbound_mails(via, sender, subject, body, confirm_link, kind, mail_to, msg_id, thread_id, sent_at)
  values (left(coalesce(p->>'via','forward'),20), left(p->>'from',200), left(p->>'subject',300), left(p->>'text',60000),
          substring(coalesce(p->>'text','') from '(https://mail[-a-z]*\.google\.com/mail/[^\s<>"]+)'),
          k, left(p->>'to',300), nullif(left(p->>'msg_id',200),''), nullif(left(p->>'thread',200),''), at)
  on conflict (msg_id) where msg_id is not null do nothing
  returning id into v;
  if k = 'inbox' then delete from private.inbound_mails where kind = 'inbox' and received_at < now() - interval '90 days'; end if;
  return v;
end $q$;
$f$;
end $p$;

-- the Booking emails list in Settings shows booking emails only
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.inbound_mails_list(int)') is null then raise notice 'no inbound_mails_list, skipped'; return; end if;
  d := pg_get_functiondef('public.inbound_mails_list(int)'::regprocedure);
  if position('kind = ''booking''' in d) > 0 then raise notice 'inbound_mails_list already patched'; return; end if;
  n := replace(d, 'from (select * from private.inbound_mails order by', 'from (select * from private.inbound_mails where kind = ''booking'' order by');
  if n = d then raise notice 'inbound_mails_list: older version, skipped'; return; end if;
  execute n;
end $p$;

-- Ask AI: search the inbox (newest first), or open one email in full. For the ask-ai function only, which checks the person first.
create or replace function public.ai_mail_read(p jsonb) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare q text := nullif(btrim(coalesce(p->>'q','')),''); fr text := nullif(btrim(coalesce(p->>'from','')),''); days int := least(90, greatest(1, coalesce(nullif(p->>'days','')::int, 14)));
  lim int := least(40, greatest(1, coalesce(nullif(p->>'limit','')::int, 20))); one uuid;
begin
  if to_regclass('private.inbound_mails') is null then return jsonb_build_object('error', 'Email is not set up in this app.'); end if;
  begin one := nullif(p->>'id','')::uuid; exception when others then one := null; end;
  if one is not null then
    return coalesce((select jsonb_build_object('id', m.id, 'at', coalesce(m.sent_at, m.received_at), 'from', m.sender, 'to', m.mail_to, 'subject', m.subject, 'thread', m.thread_id, 'kind', m.kind,
      'body', left(m.body, 20000),
      'thread_mails', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'at', coalesce(t.sent_at, t.received_at), 'from', t.sender, 'subject', t.subject) order by coalesce(t.sent_at, t.received_at)), '[]'::jsonb)
                       from private.inbound_mails t where m.thread_id is not null and t.thread_id = m.thread_id and t.id <> m.id))
      from private.inbound_mails m where m.id = one), jsonb_build_object('error', 'No email with that id.'));
  end if;
  return jsonb_build_object('emails', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'at', coalesce(m.sent_at, m.received_at), 'from', m.sender, 'to', m.mail_to, 'subject', m.subject, 'kind', m.kind,
      'start', left(regexp_replace(coalesce(m.body,''), '\s+', ' ', 'g'), 300)) order by coalesce(m.sent_at, m.received_at) desc)
    from (select * from private.inbound_mails x
          where coalesce(x.sent_at, x.received_at) > now() - make_interval(days => days)
            and (q is null or x.subject ilike '%' || q || '%' or x.body ilike '%' || q || '%' or x.sender ilike '%' || q || '%')
            and (fr is null or x.sender ilike '%' || fr || '%')
          order by coalesce(x.sent_at, x.received_at) desc limit lim) m), '[]'::jsonb),
    'set_up', exists (select 1 from private.inbound_mails where kind = 'inbox'));
end $f$;
revoke all on function public.ai_mail_read(jsonb) from public, anon, authenticated;
grant execute on function public.ai_mail_read(jsonb) to service_role;

notify pgrst, 'reload schema';
