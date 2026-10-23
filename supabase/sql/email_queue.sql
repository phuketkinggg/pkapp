-- Outreach emails sent a few at a time, so a big list does not land in spam (for example 50 partner gyms a day).
-- Rows wait as 'queued' with a send time; the mail-one function sends what is due every 10 minutes.
-- Nobody who unsubscribed, and no address already sent to in the same campaign, gets one.
alter table public.sent_emails add column if not exists to_name text;
alter table public.sent_emails add column if not exists campaign text;
alter table public.sent_emails add column if not exists send_after timestamptz;
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.sent_emails'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%' loop
    execute format('alter table public.sent_emails drop constraint %I', c);
  end loop;
end $$;
alter table public.sent_emails add constraint sent_emails_status_check check (status in ('draft','queued','sending','sent','failed','stopped'));
create index if not exists sent_emails_due on public.sent_emails (send_after) where status = 'queued';
create unique index if not exists sent_emails_campaign_to on public.sent_emails (campaign, lower(to_email)) where campaign is not null;

-- the function takes what is due (service role only)
create or replace function private.email_queue_take(p_limit int) returns jsonb language plpgsql security definer set search_path to '' as $$
declare r jsonb;
begin
  with due as (
    select e.id from public.sent_emails e
     where e.status = 'queued' and e.send_after <= now()
     order by e.send_after limit greatest(1, least(p_limit, 20)) for update skip locked),
  upd as (update public.sent_emails e set status = 'sending' from due where e.id = due.id
          returning e.id, e.to_email, e.to_name, e.subject, e.body, (select s.name from public.staff s where s.id = e.by_staff) from_name)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'to', to_email, 'name', to_name, 'subject', subject, 'body', body, 'from_name', from_name)), '[]'::jsonb) into r from upd;
  return r;
end $$;
revoke all on function private.email_queue_take(int) from public, anon, authenticated;
create or replace function public.email_queue_take(p_limit int) returns jsonb language sql security definer set search_path to '' as $$ select private.email_queue_take(p_limit) $$;
revoke all on function public.email_queue_take(int) from public, anon, authenticated;
grant execute on function public.email_queue_take(int) to service_role;

-- owner: how a campaign is going, and stop it
create or replace function public.email_campaigns() returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('campaign', campaign, 'queued', q, 'sent', s, 'failed', f, 'stopped', st, 'next', nx, 'last', ls) order by ls desc nulls last) from (
    select campaign, count(*) filter (where status = 'queued') q, count(*) filter (where status = 'sent') s, count(*) filter (where status = 'failed') f,
           count(*) filter (where status = 'stopped') st, min(send_after) filter (where status = 'queued') nx, max(sent_at) ls
    from public.sent_emails where campaign is not null group by campaign) z), '[]'::jsonb);
end $$;
revoke all on function public.email_campaigns() from public, anon;
grant execute on function public.email_campaigns() to authenticated;

create or replace function public.email_campaign_stop(p_campaign text) returns int language plpgsql security definer set search_path to '' as $$
declare n int;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can do this.'; end if;
  update public.sent_emails set status = 'stopped' where campaign = p_campaign and status = 'queued';
  get diagnostics n = row_count; return n;
end $$;
revoke all on function public.email_campaign_stop(text) from public, anon;
grant execute on function public.email_campaign_stop(text) to authenticated;

-- one address can be taken off a campaign (they replied "stop")
create or replace function public.email_campaign_drop(p_campaign text, p_email text) returns int language plpgsql security definer set search_path to '' as $$
declare n int;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the owner or an admin can do this.'; end if;
  update public.sent_emails set status = 'stopped' where campaign = p_campaign and lower(to_email) = lower(btrim(p_email)) and status = 'queued';
  get diagnostics n = row_count; return n;
end $$;
revoke all on function public.email_campaign_drop(text, text) from public, anon;
grant execute on function public.email_campaign_drop(text, text) to authenticated;
