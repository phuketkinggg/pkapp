-- Payment plan for long stays booked well ahead (feature stay_plan; Settings, Website offer, Payment plan).
-- The guest pays the first part now on the website, the card is saved by Stripe, and the rest of the plan is charged by itself
-- each month until a set number of days before arrival; what is left is paid on arrival. A payment that fails is tried again
-- every 2 days and the guest gets a link to pay; after the grace days the booking is cancelled and what was paid is kept
-- (the guest agreed to these terms before paying). The book function (mode plans, every day) does the charging.

create table if not exists public.stay_plans (
  id uuid primary key default gen_random_uuid(),
  stay_id uuid not null references public.stays(id) on delete cascade,
  customer_id uuid,
  total_thb integer not null,
  rest_thb integer not null default 0,
  items jsonb not null default '[]'::jsonb,       -- [{n, due, amount, status: due|paid|failed, tries, tried_at, paid_at, ref, link, reminded}]
  status text not null default 'pending' check (status in ('pending', 'active', 'done', 'failed', 'cancelled')),
  acct text not null default 'main',               -- which Stripe account holds the saved card
  first_session text,
  stripe_customer text,
  payment_method text,
  fail_since date,
  terms text,
  agreed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists stay_plans_stay_key on public.stay_plans (stay_id);
alter table public.stay_plans enable row level security;
revoke all on public.stay_plans from public, anon, authenticated;

-- the team: the plan on a stay (paid so far, what is next)
create or replace function public.stay_plan_view(p_stay uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare p public.stay_plans;
begin
  if private.staff_role() is null then raise exception 'Only the team can see this.'; end if;
  select * into p from public.stay_plans where stay_id = p_stay;
  if p.id is null then return null; end if;
  return jsonb_build_object('status', p.status, 'total', p.total_thb, 'rest', p.rest_thb, 'items', p.items, 'fail_since', p.fail_since, 'terms', p.terms, 'agreed_at', p.agreed_at,
    'card_saved', p.payment_method is not null);
end $f$;
revoke all on function public.stay_plan_view(uuid) from public, anon;
grant execute on function public.stay_plan_view(uuid) to authenticated;

-- the daily run (book function, mode plans): charge what is due, remind, follow up failed payments
create or replace function private.stay_plans_run() returns void language plpgsql security definer set search_path to '' as $f$
declare base text; tok text;
begin
  if not private.feature('stay_plan', true) then return; end if;
  if not exists (select 1 from public.stay_plans where status in ('pending', 'active')) then return; end if;
  select value into base from private.sync_settings where key = 'functions_url';
  select value into tok from private.sync_settings where key = 'sync_token';
  if tok is null then return; end if;
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/book', headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', tok),
    body := '{"mode":"plans"}'::jsonb, timeout_milliseconds := 120000);
end $f$;
revoke all on function private.stay_plans_run() from public, anon, authenticated;

do $c$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'stay-plans';
    perform cron.schedule('stay-plans', '7 3,9 * * *', 'select private.stay_plans_run()');
  end if;
end $c$;

-- the booking page, after paying: says it is a payment plan (patches web_booking_status where it has the deposit fields)
do $p$
declare d text; n text; a text := '''pay_now'', s.web_pay_now_thb,';
begin
  if to_regprocedure('public.web_booking_status(uuid)') is null then raise notice 'web_booking_status: not here, skipped'; return; end if;
  d := pg_get_functiondef('public.web_booking_status(uuid)'::regprocedure);
  if position('stay_plans' in d) > 0 then raise notice 'web_booking_status: already shows plans'; return; end if;
  if position(a in d) = 0 then raise notice 'web_booking_status: an older version, skipped'; return; end if;
  n := replace(d, a, a || ' ''plan'', exists (select 1 from public.stay_plans sp where sp.stay_id = s.id),');
  execute n;
  if position('stay_plans' in pg_get_functiondef('public.web_booking_status(uuid)'::regprocedure)) = 0 then raise exception 'web_booking_status was not patched'; end if;
end $p$;

notify pgrst, 'reload schema';
