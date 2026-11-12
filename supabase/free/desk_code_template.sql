delete from mf.template where name like 'desk_code:%';
insert into mf.template (ord, phase, kind, name, sql) values (302301, 3, 'patch', 'desk_code:302301', $TPL$create table if not exists __Q__.desk_code (
  id int primary key default 1 check (id = 1),
  hash text,
  allow text[] not null default array['pay','checkin_unpaid','kiosk_exit'],
  updated_at timestamptz,
  updated_by uuid
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (302302, 3, 'patch', 'desk_code:302302', $TPL$create table if not exists __Q__.desk_code_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  ok boolean not null,
  what text,
  customer_id uuid,
  amount int,
  by_staff uuid
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196301, 11, 'patch', 'desk_code:1196301', $TPL$revoke all on __Q__.desk_code, __Q__.desk_code_log from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402301, 4, 'patch', 'desk_code:402301', $TPL$create or replace function __Q__.desk_code_ok(p_code text, p_what text, p_customer uuid default null, p_amount int default null) returns boolean
language plpgsql security definer set search_path to '' as $f$
declare d __Q__.desk_code; ok boolean;
begin
  if not __Q__.feature('desk_code', true) then raise exception 'The front desk code is switched off in Settings, Features.'; end if;
  if not __Q__.is_desk() then raise exception 'Only the front desk can do this.'; end if;
  select * into d from __Q__.desk_code where id = 1;
  if d.hash is null then raise exception 'No front desk code yet. A manager sets it in Settings, Front desk code.'; end if;
  if not (p_what = any (d.allow)) then raise exception 'The front desk code is not allowed for this. A manager can allow it in Settings, Front desk code.'; end if;
  if (select count(*) from __Q__.desk_code_log l where not l.ok and l.at > now() - interval '10 minutes') >= 5 then
    raise exception 'Too many wrong codes. Wait 15 minutes, or ask a manager.'; end if;
  ok := coalesce(p_code, '') ~ '^\d{6}$' and d.hash = extensions.crypt(p_code, d.hash);
  insert into __Q__.desk_code_log (ok, what, customer_id, amount, by_staff) values (ok, p_what, p_customer, p_amount, __Q__.my_staff_id());
  return ok;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196302, 11, 'patch', 'desk_code:1196302', $TPL$revoke all on function __Q__.desk_code_ok(text, text, uuid, int) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402302, 4, 'patch', 'desk_code:402302', $TPL$create or replace function __P__.desk_code_settings() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_build_object('set', d.hash is not null, 'allow', to_jsonb(d.allow), 'updated_at', d.updated_at,
      'by', (select s.name from __P__.staff s where s.id = d.updated_by)) from __Q__.desk_code d where d.id = 1),
    jsonb_build_object('set', false, 'allow', jsonb_build_array('pay','checkin_unpaid','kiosk_exit')));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402303, 4, 'patch', 'desk_code:402303', $TPL$create or replace function __P__.desk_code_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare c text := nullif(btrim(coalesce(p->>'code', '')), ''); a text[];
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change the front desk code.'; end if;
  if c is not null and c !~ '^\d{6}$' then raise exception 'The code must be 6 numbers.'; end if;
  if c is not null and c ~ '^(\d)\1{5}$|^(012345|123456|234567|345678|456789|987654|876543|765432|654321|543210)$' then
    raise exception 'Choose a code that is harder to guess than %.', c; end if;
  a := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'allow', '[]'::jsonb)) x where x in ('pay','checkin_unpaid','kiosk_exit')), '{}');
  insert into __Q__.desk_code (id, hash, allow, updated_at, updated_by) values (1, case when c is not null then extensions.crypt(c, extensions.gen_salt('bf')) end, a, now(), __Q__.my_staff_id())
  on conflict (id) do update set hash = case when c is not null then excluded.hash when coalesce((p->>'clear')::boolean, false) then null else __Q__.desk_code.hash end,
    allow = excluded.allow, updated_at = now(), updated_by = excluded.updated_by;
  return __P__.desk_code_settings();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402304, 4, 'patch', 'desk_code:402304', $TPL$create or replace function __P__.desk_code_uses() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', l.at, 'ok', l.ok, 'what', l.what, 'amount', l.amount,
      'customer', (select c.name from __P__.customers c where c.id = l.customer_id), 'by', (select s.name from __P__.staff s where s.id = l.by_staff)) order by l.at desc)
    from (select * from __Q__.desk_code_log where at > now() - interval '60 days' order by at desc limit 300) l), '[]'::jsonb);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402305, 4, 'patch', 'desk_code:402305', $TPL$create or replace function __P__.desk_code_pay(p_customer uuid, p_amount integer, p_method text, p_code text) returns jsonb
language plpgsql security definer set search_path to '' as $f$
begin
  if p_method not in ('cash','qr') then raise exception 'Choose cash or PromptPay.'; end if;
  -- a wrong code returns ok false (not an error), so the wrong try stays in the log and counts towards the lock
  if not __Q__.desk_code_ok(p_code, 'pay', p_customer, p_amount) then return jsonb_build_object('ok', false); end if;
  return __P__.pay_customer(p_customer, p_amount, p_method, 'Taken at the check in screen, confirmed with the front desk code') || jsonb_build_object('ok', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (402306, 4, 'patch', 'desk_code:402306', $TPL$create or replace function __P__.desk_code_check(p_code text, p_what text, p_customer uuid default null) returns boolean
language plpgsql security definer set search_path to '' as $f$
begin
  if p_what not in ('checkin_unpaid','kiosk_exit') then raise exception 'Unknown use.'; end if;
  return __Q__.desk_code_ok(p_code, p_what, p_customer, case when p_customer is not null and p_what = 'checkin_unpaid' then __Q__.customer_owes(p_customer) end);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196303, 11, 'patch', 'desk_code:1196303', $TPL$revoke all on function __P__.desk_code_settings(), __P__.desk_code_save(jsonb), __P__.desk_code_uses(), __P__.desk_code_pay(uuid, integer, text, text), __P__.desk_code_check(text, text, uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1196304, 11, 'patch', 'desk_code:1196304', $TPL$grant execute on function __P__.desk_code_settings(), __P__.desk_code_save(jsonb), __P__.desk_code_uses(), __P__.desk_code_pay(uuid, integer, text, text), __P__.desk_code_check(text, text, uuid) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'desk_code:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
