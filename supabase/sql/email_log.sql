-- Emails page: every email the app has sent or will send, in one list (manager only).
-- Written emails and invoices (sent_emails, including outreach waiting to go), stay welcome emails (stay_emails)
-- and action group step emails (group_email_log). Replies are not here: they go to the business inbox.
create or replace function public.email_log(p_filter text default 'all', p_q text default null, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare q text := lower(btrim(coalesce(p_q,'')));
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see the emails.'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'at') desc nulls last) from (
    select x from (
      select jsonb_build_object('id', e.id, 'src', 'mail', 'kind', case when e.campaign is not null then 'Outreach: ' || e.campaign when e.subject ilike 'Invoice %' or e.subject ilike 'Receipt %' or e.subject ilike 'Deposit receipt %' then 'Invoice' else 'Written in the app' end,
        'to', e.to_email, 'name', coalesce(e.to_name, (select c.name from public.customers c where c.id = e.customer_id)), 'subject', e.subject, 'body', e.body,
        'status', e.status, 'error', e.error, 'at', coalesce(e.sent_at, e.send_after, e.created_at), 'customer_id', e.customer_id,
        'by', (select s.name from public.staff s where s.id = e.by_staff)) x
      from public.sent_emails e
      union all
      select jsonb_build_object('id', w.id, 'src', 'stay', 'kind', 'Stay welcome email', 'to', w.to_email, 'name', (select c.name from public.stays s join public.customers c on c.id = s.customer_id where s.id = w.stay_id),
        'subject', 'Welcome email for the stay', 'body', null, 'status', case when w.ok then 'sent' else 'failed' end, 'error', w.error, 'at', w.sent_at, 'by', case when w.auto then 'Automatic' end)
      from public.stay_emails w
      union all
      select jsonb_build_object('id', g.member_id::text || g.item_id, 'src', 'group', 'kind', 'Action group step', 'to', g.sent_to, 'name', (select c.name from public.customers c where c.id = g.customer_id),
        'subject', 'Action group step email', 'body', null, 'status', case when g.sent_at is not null then 'sent' when g.error is not null then 'failed' else 'queued' end, 'error', g.error, 'at', coalesce(g.sent_at, g.created_at), 'by', 'Automatic')
      from public.group_email_log g
    ) a
    where (p_filter = 'all' or (p_filter = 'sent' and x->>'status' = 'sent') or (p_filter = 'waiting' and x->>'status' in ('queued','draft')) or (p_filter = 'failed' and x->>'status' in ('failed','stopped')))
      and (q = '' or lower(coalesce(x->>'to','') || ' ' || coalesce(x->>'name','') || ' ' || coalesce(x->>'subject','') || ' ' || coalesce(x->>'kind','')) like '%' || q || '%')
    order by (x->>'at') desc nulls last limit greatest(1, least(coalesce(p_limit,200), 1000))
  ) b), '[]'::jsonb);
end $$;
revoke all on function public.email_log(text, text, int) from public, anon;
grant execute on function public.email_log(text, text, int) to authenticated;
