delete from mf.template where name like 'stay_plans:%';
insert into mf.template (ord, phase, kind, name, sql) values (303521, 3, 'patch', 'stay_plans:303521', $TPL$create table if not exists __P__.stay_plans (
  id uuid primary key default gen_random_uuid(),
  stay_id uuid not null references __P__.stays(id) on delete cascade,
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
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002221, 10, 'patch', 'stay_plans:1002221', $TPL$create unique index if not exists stay_plans_stay_key on __P__.stay_plans (stay_id);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303522, 3, 'patch', 'stay_plans:303522', $TPL$alter table __P__.stay_plans enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197661, 11, 'patch', 'stay_plans:1197661', $TPL$revoke all on __P__.stay_plans from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403661, 4, 'patch', 'stay_plans:403661', $TPL$create or replace function __P__.stay_plan_view(p_stay uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare p __P__.stay_plans;
begin
  if __Q__.staff_role() is null then raise exception 'Only the team can see this.'; end if;
  select * into p from __P__.stay_plans where stay_id = p_stay;
  if p.id is null then return null; end if;
  return jsonb_build_object('status', p.status, 'total', p.total_thb, 'rest', p.rest_thb, 'items', p.items, 'fail_since', p.fail_since, 'terms', p.terms, 'agreed_at', p.agreed_at,
    'card_saved', p.payment_method is not null);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197662, 11, 'patch', 'stay_plans:1197662', $TPL$revoke all on function __P__.stay_plan_view(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197663, 11, 'patch', 'stay_plans:1197663', $TPL$grant execute on function __P__.stay_plan_view(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403662, 4, 'patch', 'stay_plans:403662', $TPL$create or replace function __Q__.stay_plans_run() returns void language plpgsql security definer set search_path to '' as $f$
declare base text; tok text;
begin
  if not __Q__.feature('stay_plan', true) then return; end if;
  if not exists (select 1 from __P__.stay_plans where status in ('pending', 'active')) then return; end if;
  select value into base from __Q__.sync_settings where key = 'functions_url';
  select value into tok from __Q__.sync_settings where key = 'sync_token';
  if base is null or tok is null then return; end if;
  perform net.http_post(url := base || '/book', headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', tok),
    body := '{"mode":"plans"}'::jsonb, timeout_milliseconds := 120000);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197664, 11, 'patch', 'stay_plans:1197664', $TPL$revoke all on function __Q__.stay_plans_run() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002222, 10, 'patch', 'stay_plans:1002222', $TPL$do $p$
declare d text; n text; a text := '''pay_now'', s.web_pay_now_thb,';
begin
  if to_regprocedure('__P__.web_booking_status(uuid)') is null then raise notice 'web_booking_status: not here, skipped'; return; end if;
  d := pg_get_functiondef('__P__.web_booking_status(uuid)'::regprocedure);
  if position('stay_plans' in d) > 0 then raise notice 'web_booking_status: already shows plans'; return; end if;
  if position(a in d) = 0 then raise notice 'web_booking_status: an older version, skipped'; return; end if;
  n := replace(d, a, a || ' ''plan'', exists (select 1 from __P__.stay_plans sp where sp.stay_id = s.id),');
  execute n;
  if position('stay_plans' in pg_get_functiondef('__P__.web_booking_status(uuid)'::regprocedure)) = 0 then raise exception 'web_booking_status was not patched'; end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'stay_plans:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
