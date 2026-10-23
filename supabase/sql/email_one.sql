-- One email to one person from the app (outreach, a reply, a follow up), sent from hello@phuketking.com.
-- The owner or an admin writes it on a contact's page; it is kept as a draft until they press Send.
-- Replies come back to hello@phuketking.com. Every email sent is kept on the contact's page.
create table if not exists public.sent_emails (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete set null,
  to_email text not null check (to_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(to_email) <= 200),
  subject text not null default '' check (char_length(subject) <= 200),
  body text not null default '' check (char_length(body) <= 20000),
  status text not null default 'draft' check (status in ('draft','sending','sent','failed')),
  error text,
  resend_id text,
  by_staff uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index if not exists sent_emails_customer on public.sent_emails (customer_id, created_at desc);
alter table public.sent_emails enable row level security;
revoke all on public.sent_emails from anon, authenticated;

-- list a contact's emails (drafts and sent)
create or replace function public.email_one_list(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can send emails.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'to', e.to_email, 'subject', e.subject, 'body', e.body, 'status', e.status, 'error', e.error,
      'at', coalesce(e.sent_at, e.created_at), 'by', (select s.name from public.staff s where s.id = e.by_staff)) order by coalesce(e.sent_at, e.created_at) desc)
    from public.sent_emails e where e.customer_id = p_customer), '[]'::jsonb);
end $$;
revoke all on function public.email_one_list(uuid) from public, anon;
grant execute on function public.email_one_list(uuid) to authenticated;

-- save a draft (new, or change one not sent yet); returns its id
create or replace function public.email_one_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $$
declare i uuid := nullif(p->>'id','')::uuid; c uuid := nullif(p->>'customer_id','')::uuid;
  t text := lower(btrim(coalesce(p->>'to',''))); s text := btrim(coalesce(p->>'subject','')); b text := coalesce(p->>'body','');
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can send emails.'; end if;
  if t !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address.'; end if;
  if i is not null then
    update public.sent_emails set to_email = t, subject = s, body = b, status = 'draft', error = null
     where id = i and status in ('draft','failed') returning id into i;
    if i is null then raise exception 'That email was already sent.'; end if;
    return i;
  end if;
  insert into public.sent_emails (customer_id, to_email, subject, body, by_staff) values (c, t, s, b, private.my_staff_id()) returning id into i;
  return i;
end $$;
revoke all on function public.email_one_save(jsonb) from public, anon;
grant execute on function public.email_one_save(jsonb) to authenticated;

-- the email function claims a draft before sending (so it can only go once); at most 100 a day
create or replace function public.email_one_claim(p_id uuid) returns jsonb language plpgsql security definer set search_path to '' as $$
declare r public.sent_emails; nm text;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can send emails.'; end if;
  if (select count(*) from public.sent_emails where status = 'sent' and sent_at > now() - interval '1 day') >= 100 then raise exception 'That is 100 emails today. Try again tomorrow.'; end if;
  update public.sent_emails set status = 'sending', by_staff = coalesce(private.my_staff_id(), by_staff)
   where id = p_id and status in ('draft','failed') returning * into r;
  if r.id is null then raise exception 'That email was already sent.'; end if;
  if btrim(r.subject) = '' or btrim(r.body) = '' then
    update public.sent_emails set status = 'draft' where id = r.id; raise exception 'Add a subject and a message.';
  end if;
  select s.name into nm from public.staff s where s.id = r.by_staff;
  return jsonb_build_object('id', r.id, 'to', r.to_email, 'subject', r.subject, 'body', r.body, 'from_name', nm);
end $$;
revoke all on function public.email_one_claim(uuid) from public, anon;
grant execute on function public.email_one_claim(uuid) to authenticated;

-- remove a draft
create or replace function public.email_one_drop(p_id uuid) returns void language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can send emails.'; end if;
  update public.sent_emails set customer_id = null, status = 'failed', error = 'removed' where id = p_id and status = 'draft';
end $$;
revoke all on function public.email_one_drop(uuid) from public, anon;
grant execute on function public.email_one_drop(uuid) to authenticated;
