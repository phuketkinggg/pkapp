-- Email steps in action groups: a coach writes an email (subject and message) and schedules it like any other step,
-- on day N or week N after the person's start date in the group, or on a fixed date. The group-email function sends what is due
-- (from the hour set in app_settings group_email, Bangkok time) and logs each one so nobody gets the same email twice.

-- group steps may now be emails (the subject is required)
do $$ declare d text := pg_get_functiondef('public.group_save(jsonb)'::regprocedure); begin
  if position('''email''' in d) = 0 then
    d := replace(d, $a$not in ('video','doc','note','habit','food','weight','program') then raise exception 'Unknown step type.'; end if;$a$,
      $b$not in ('video','doc','note','habit','food','weight','program','email') then raise exception 'Unknown step type.'; end if;
    if x->>'kind' = 'email' and btrim(coalesce(x->>'title','')) = '' then raise exception 'Give every email a subject.'; end if;
    if x->>'kind' = 'email' and btrim(coalesce(x->>'text','')) = '' then raise exception 'Write the message for "%".', x->>'title'; end if;$b$);
    if position('''email''' in d) = 0 then raise exception 'group_save patch did not apply'; end if;
    execute d;
  end if;
end $$;

create table if not exists public.group_email_log(
  member_id uuid not null references public.group_members(id) on delete cascade,
  item_id text not null,
  customer_id uuid,
  sent_at timestamptz, sent_to text, tries int not null default 0, error text,
  created_at timestamptz not null default now(),
  primary key (member_id, item_id)
);
alter table public.group_email_log enable row level security;
revoke all on public.group_email_log from anon, authenticated;

insert into public.app_settings(key, value) values ('group_email', '{"hour":9}') on conflict (key) do nothing;

-- what is due now. A step is sent on its day (from the set hour) or up to 2 days late, never for days before the person joined,
-- and never to anyone who unsubscribed.
create or replace function public.group_emails_due() returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare t date := private.bkk_today(); hr int; now_h int := extract(hour from (now() at time zone 'Asia/Bangkok'))::int;
begin
  select coalesce(nullif((case when value ~ '^\s*\{' then value::jsonb end)->>'hour','')::int, 9) into hr from public.app_settings where key='group_email';
  hr := coalesce(hr, 9);
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('member_id', m.id, 'item_id', it->>'id', 'customer_id', c.id, 'name', c.name, 'email', lower(btrim(c.email)), 'token', c.email_token,
      'subject', it->>'title', 'text', it->>'text', 'url', nullif(it->>'url',''), 'button', nullif(btrim(coalesce(it->>'button','')),''), 'group', g.name) x
    from public.group_members m
    join public.action_groups g on g.id = m.group_id and not g.removed
    join public.customers c on c.id = m.customer_id
    cross join lateral jsonb_array_elements(g.items) it
    cross join lateral (select private.step_on(it, m.start_on) d) s
    where not m.removed and it->>'kind' = 'email'
      and s.d <= t and s.d >= t - 2 and s.d >= (m.added_at at time zone 'Asia/Bangkok')::date
      and (s.d < t or now_h >= hr)
      and c.unsubscribed_at is null and coalesce(c.email,'') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
      and not exists (select 1 from public.group_email_log l where l.member_id = m.id and l.item_id = it->>'id' and (l.sent_at is not null or l.tries >= 3))
    limit 50) q), '[]'::jsonb);
end $f$;
revoke all on function public.group_emails_due() from public, anon, authenticated;
grant execute on function public.group_emails_due() to service_role;

create or replace function public.group_email_mark(p_member uuid, p_item text, p_customer uuid, p_to text, p_ok boolean, p_error text) returns void
language sql security definer set search_path='' as $f$
  insert into public.group_email_log(member_id, item_id, customer_id, sent_at, sent_to, tries, error)
  values (p_member, p_item, p_customer, case when p_ok then now() end, p_to, 1, case when not p_ok then left(p_error, 300) end)
  on conflict (member_id, item_id) do update set sent_at = coalesce(public.group_email_log.sent_at, excluded.sent_at), sent_to = excluded.sent_to,
    tries = public.group_email_log.tries + 1, error = excluded.error
$f$;
revoke all on function public.group_email_mark(uuid, text, uuid, text, boolean, text) from public, anon, authenticated;
grant execute on function public.group_email_mark(uuid, text, uuid, text, boolean, text) to service_role;

-- coaches see which emails a client got
create or replace function public.group_email_status(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path='' as $f$
begin
  if not private.coach_can(p_customer) and not private.coach_staff() then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('member_id', l.member_id, 'item_id', l.item_id, 'sent_at', l.sent_at, 'error', case when l.sent_at is null then l.error end))
    from public.group_email_log l where l.customer_id = p_customer), '[]'::jsonb);
end $f$;
revoke all on function public.group_email_status(uuid) from public, anon;
grant execute on function public.group_email_status(uuid) to authenticated;

-- every 15 minutes
select cron.unschedule('group-emails') where exists (select 1 from cron.job where jobname = 'group-emails');
select cron.schedule('group-emails', '7,22,37,52 * * * *', $c$
  select net.http_post(
    url := 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/group-email',
    headers := jsonb_build_object('Content-Type','application/json','x-sync-token',(select value from private.sync_settings where key='sync_token')),
    body := '{"mode":"auto"}'::jsonb,
    timeout_milliseconds := 120000)
  where exists (select 1 from public.action_groups where not removed and items @> '[{"kind":"email"}]')
$c$);
