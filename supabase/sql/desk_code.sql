-- Front desk code (feature desk_code): a 6 digit code a manager sets in Settings. On the check in screen (desk mode) the front
-- desk types it to confirm what a manager allows: mark cash or PromptPay as paid (the person can then check in), let someone check
-- in now and pay later, and leave desk mode. Only a hash of the code is kept. After 5 wrong codes in 10 minutes it is locked for
-- 15 minutes. Every use is logged with what it was for.

create table if not exists private.desk_code (
  id int primary key default 1 check (id = 1),
  hash text,
  allow text[] not null default array['pay','checkin_unpaid','kiosk_exit'],
  updated_at timestamptz,
  updated_by uuid
);
create table if not exists private.desk_code_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  ok boolean not null,
  what text,
  customer_id uuid,
  amount int,
  by_staff uuid
);
revoke all on private.desk_code, private.desk_code_log from public, anon, authenticated;

-- checks the code for one thing it may be used for, with the lock after wrong tries; logs every try. A wrong code returns false
-- (never an error), so the log row is kept.
create or replace function private.desk_code_ok(p_code text, p_what text, p_customer uuid default null, p_amount int default null) returns boolean
language plpgsql security definer set search_path to '' as $f$
declare d private.desk_code; ok boolean;
begin
  if not private.feature('desk_code', true) then raise exception 'The front desk code is switched off in Settings, Features.'; end if;
  if not private.is_desk() then raise exception 'Only the front desk can do this.'; end if;
  select * into d from private.desk_code where id = 1;
  if d.hash is null then raise exception 'No front desk code yet. A manager sets it in Settings, Front desk code.'; end if;
  if not (p_what = any (d.allow)) then raise exception 'The front desk code is not allowed for this. A manager can allow it in Settings, Front desk code.'; end if;
  if (select count(*) from private.desk_code_log l where not l.ok and l.at > now() - interval '10 minutes') >= 5 then
    raise exception 'Too many wrong codes. Wait 15 minutes, or ask a manager.'; end if;
  ok := coalesce(p_code, '') ~ '^\d{6}$' and d.hash = extensions.crypt(p_code, d.hash);
  insert into private.desk_code_log (ok, what, customer_id, amount, by_staff) values (ok, p_what, p_customer, p_amount, private.my_staff_id());
  return ok;
end $f$;
revoke all on function private.desk_code_ok(text, text, uuid, int) from public, anon, authenticated;

-- the settings, for a manager
create or replace function public.desk_code_settings() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_build_object('set', d.hash is not null, 'allow', to_jsonb(d.allow), 'updated_at', d.updated_at,
      'by', (select s.name from public.staff s where s.id = d.updated_by)) from private.desk_code d where d.id = 1),
    jsonb_build_object('set', false, 'allow', jsonb_build_array('pay','checkin_unpaid','kiosk_exit')));
end $f$;
create or replace function public.desk_code_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare c text := nullif(btrim(coalesce(p->>'code', '')), ''); a text[];
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change the front desk code.'; end if;
  if c is not null and c !~ '^\d{6}$' then raise exception 'The code must be 6 numbers.'; end if;
  if c is not null and c ~ '^(\d)\1{5}$|^(012345|123456|234567|345678|456789|987654|876543|765432|654321|543210)$' then
    raise exception 'Choose a code that is harder to guess than %.', c; end if;
  a := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'allow', '[]'::jsonb)) x where x in ('pay','checkin_unpaid','kiosk_exit')), '{}');
  insert into private.desk_code (id, hash, allow, updated_at, updated_by) values (1, case when c is not null then extensions.crypt(c, extensions.gen_salt('bf')) end, a, now(), private.my_staff_id())
  on conflict (id) do update set hash = case when c is not null then excluded.hash when coalesce((p->>'clear')::boolean, false) then null else private.desk_code.hash end,
    allow = excluded.allow, updated_at = now(), updated_by = excluded.updated_by;
  return public.desk_code_settings();
end $f$;
-- who used the code, last 60 days, for a manager
create or replace function public.desk_code_uses() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', l.at, 'ok', l.ok, 'what', l.what, 'amount', l.amount,
      'customer', (select c.name from public.customers c where c.id = l.customer_id), 'by', (select s.name from public.staff s where s.id = l.by_staff)) order by l.at desc)
    from (select * from private.desk_code_log where at > now() - interval '60 days' order by at desc limit 300) l), '[]'::jsonb);
end $f$;

-- the desk takes cash or PromptPay at the check in screen and confirms with the code
create or replace function public.desk_code_pay(p_customer uuid, p_amount integer, p_method text, p_code text) returns jsonb
language plpgsql security definer set search_path to '' as $f$
begin
  if p_method not in ('cash','qr') then raise exception 'Choose cash or PromptPay.'; end if;
  -- a wrong code returns ok false (not an error), so the wrong try stays in the log and counts towards the lock
  if not private.desk_code_ok(p_code, 'pay', p_customer, p_amount) then return jsonb_build_object('ok', false); end if;
  return public.pay_customer(p_customer, p_amount, p_method, 'Taken at the check in screen, confirmed with the front desk code') || jsonb_build_object('ok', true);
end $f$;
-- the code for something that does not change data here (check in now, pay later; leave desk mode)
create or replace function public.desk_code_check(p_code text, p_what text, p_customer uuid default null) returns boolean
language plpgsql security definer set search_path to '' as $f$
begin
  if p_what not in ('checkin_unpaid','kiosk_exit') then raise exception 'Unknown use.'; end if;
  return private.desk_code_ok(p_code, p_what, p_customer, case when p_customer is not null and p_what = 'checkin_unpaid' then private.customer_owes(p_customer) end);
end $f$;

revoke all on function public.desk_code_settings(), public.desk_code_save(jsonb), public.desk_code_uses(), public.desk_code_pay(uuid, integer, text, text), public.desk_code_check(text, text, uuid) from public, anon;
grant execute on function public.desk_code_settings(), public.desk_code_save(jsonb), public.desk_code_uses(), public.desk_code_pay(uuid, integer, text, text), public.desk_code_check(text, text, uuid) to authenticated;

notify pgrst, 'reload schema';
