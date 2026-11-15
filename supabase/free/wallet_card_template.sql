delete from mf.template where name like 'wallet_card:%';
insert into mf.template (ord, phase, kind, name, sql) values (303501, 3, 'patch', 'wallet_card:303501', $TPL$alter table __P__.customers add column if not exists card_token uuid not null default gen_random_uuid();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002201, 10, 'patch', 'wallet_card:1002201', $TPL$create unique index if not exists customers_card_token_key on __P__.customers (card_token);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303502, 3, 'patch', 'wallet_card:303502', $TPL$create table if not exists __P__.wallet_devices (
  device_id text not null,
  card_token uuid not null,
  push_token text not null,
  created_at timestamptz not null default now(),
  primary key (device_id, card_token)
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303503, 3, 'patch', 'wallet_card:303503', $TPL$alter table __P__.wallet_devices enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197621, 11, 'patch', 'wallet_card:1197621', $TPL$revoke all on __P__.wallet_devices from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303504, 3, 'patch', 'wallet_card:303504', $TPL$create table if not exists __P__.wallet_updates (
  card_token uuid primary key,
  updated_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303505, 3, 'patch', 'wallet_card:303505', $TPL$alter table __P__.wallet_updates enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197622, 11, 'patch', 'wallet_card:1197622', $TPL$revoke all on __P__.wallet_updates from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403621, 4, 'patch', 'wallet_card:403621', $TPL$create or replace function __P__.my_card() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare c record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not __Q__.feature('wallet_card', true) then return null; end if;
  select id, card_token, name into c from __P__.customers where user_id = auth.uid() order by created_at limit 1;
  if c.id is null then return null; end if;
  return jsonb_build_object('token', c.card_token, 'name', c.name);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403622, 4, 'patch', 'wallet_card:403622', $TPL$create or replace function __P__.card_token_for(p_customer uuid) returns uuid language plpgsql stable security definer set search_path to '' as $f$
begin
  if __Q__.staff_role() is null then raise exception 'Only the team can do this.'; end if;
  return (select card_token from __P__.customers where id = p_customer);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403623, 4, 'patch', 'wallet_card:403623', $TPL$create or replace function __P__.card_find(p_token text) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare c record; t text := lower(btrim(coalesce(p_token, '')));
begin
  if __Q__.staff_role() is null then raise exception 'Only the team can do this.'; end if;
  t := coalesce(substring(t from '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'), '');
  if t = '' then return null; end if;
  select id, name, email, phone into c from __P__.customers where card_token = t::uuid;
  if c.id is null then return null; end if;
  return jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403624, 4, 'patch', 'wallet_card:403624', $TPL$create or replace function __P__.card_data(p_token uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare c record; p record; today date := (now() at time zone __Q__.tz())::date; s jsonb;
begin
  select id, name, card_token into c from __P__.customers where card_token = p_token;
  if c.id is null then return null; end if;
  select x.package_name, x.expires_on, x.visit_limit, x.visits_left, x.per_week_limit, x.starts_on into p
    from __P__.purchases x
    where x.customer_id = c.id and not x.cancelled and x.upgrade_done_at is null and (x.expires_on is null or x.expires_on >= today)
      and not ('Privates' = any(coalesce(x.covers, '{}')) and coalesce(array_length(x.covers, 1), 0) = 1)
    order by (x.starts_on is null or x.starts_on <= today) desc, x.expires_on desc nulls last, x.purchased_on desc limit 1;
  s := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'wallet_card'), '{}'::jsonb);
  return jsonb_build_object('name', c.name, 'token', c.card_token, 'biz', __Q__.biz_main(), 'on', __Q__.feature('wallet_card', true),
    'theme', coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'app_theme'), '{}'::jsonb),
    'settings', s, 'region', __P__.app_region(), 'today', today,
    'package', case when p.package_name is null then null else jsonb_build_object('name', p.package_name, 'until', p.expires_on, 'starts', p.starts_on,
      'left', case when p.visit_limit is null then null else coalesce(p.visits_left, p.visit_limit) end, 'week', p.per_week_limit) end,
    'updated', coalesce((select updated_at from __P__.wallet_updates where card_token = c.card_token), now()));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403625, 4, 'patch', 'wallet_card:403625', $TPL$create or replace function __Q__.card_changed() returns trigger language plpgsql security definer set search_path to '' as $f$
declare cid uuid := coalesce(new.customer_id, old.customer_id); tok uuid; v_base text; v_key text;
begin
  if cid is null then return coalesce(new, old); end if;
  select card_token into tok from __P__.customers where id = cid;
  if tok is null or not exists (select 1 from __P__.wallet_devices where card_token = tok) then return coalesce(new, old); end if;
  insert into __P__.wallet_updates (card_token, updated_at) values (tok, now()) on conflict (card_token) do update set updated_at = now();
  begin
    select value into v_base from __Q__.sync_settings where key = 'functions_url';
    select value into v_key from __Q__.sync_settings where key = 'sync_token';
    if v_base is not null and v_key is not null then
      perform net.http_post(url := v_base || '/wallet?k=push', headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', v_key),
        body := jsonb_build_object('token', tok), timeout_milliseconds := 20000);
    end if;
  exception when others then null;
  end;
  return coalesce(new, old);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901761, 9, 'patch', 'wallet_card:901761', $TPL$drop trigger if exists card_changed on __P__.purchases;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901762, 9, 'patch', 'wallet_card:901762', $TPL$create trigger card_changed after insert or update on __P__.purchases for each row execute function __Q__.card_changed();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901763, 9, 'patch', 'wallet_card:901763', $TPL$drop trigger if exists card_changed on __P__.checkins;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (901764, 9, 'patch', 'wallet_card:901764', $TPL$create trigger card_changed after insert or delete on __P__.checkins for each row execute function __Q__.card_changed();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197623, 11, 'patch', 'wallet_card:1197623', $TPL$revoke all on function __P__.my_card() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197624, 11, 'patch', 'wallet_card:1197624', $TPL$revoke all on function __P__.card_token_for(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197625, 11, 'patch', 'wallet_card:1197625', $TPL$revoke all on function __P__.card_find(text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197626, 11, 'patch', 'wallet_card:1197626', $TPL$revoke all on function __P__.card_data(uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197627, 11, 'patch', 'wallet_card:1197627', $TPL$revoke all on function __Q__.card_changed() from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197628, 11, 'patch', 'wallet_card:1197628', $TPL$grant execute on function __P__.my_card() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197629, 11, 'patch', 'wallet_card:1197629', $TPL$grant execute on function __P__.card_token_for(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197630, 11, 'patch', 'wallet_card:1197630', $TPL$grant execute on function __P__.card_find(text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197631, 11, 'patch', 'wallet_card:1197631', $TPL$grant execute on function __P__.card_data(uuid) to service_role;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'wallet_card:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
