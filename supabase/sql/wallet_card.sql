-- Member card in Apple Wallet and Google Wallet (feature wallet_card). Each customer has a secret card token: the QR code on the card
-- is PKCARD:<token>, the front desk scans it to find them and check them in. The card shows the current package, classes left and
-- the end date, and updates itself on iPhones when a package is sold or a class is used (wallet function, Apple push).

alter table public.customers add column if not exists card_token uuid not null default gen_random_uuid();
create unique index if not exists customers_card_token_key on public.customers (card_token);

-- iPhones that saved a card, so it can be told to update (Apple Wallet web service)
create table if not exists public.wallet_devices (
  device_id text not null,
  card_token uuid not null,
  push_token text not null,
  created_at timestamptz not null default now(),
  primary key (device_id, card_token)
);
alter table public.wallet_devices enable row level security;
revoke all on public.wallet_devices from public, anon, authenticated;
create table if not exists public.wallet_updates (
  card_token uuid primary key,
  updated_at timestamptz not null default now()
);
alter table public.wallet_updates enable row level security;
revoke all on public.wallet_updates from public, anon, authenticated;

-- the member: their own card token (Add to Wallet in the member app)
create or replace function public.my_card() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare c record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not private.feature('wallet_card', true) then return null; end if;
  select id, card_token, name into c from public.customers where user_id = auth.uid() order by created_at limit 1;
  if c.id is null then return null; end if;
  return jsonb_build_object('token', c.card_token, 'name', c.name);
end $f$;

-- the team: a customer's card token (to send them the Add to Wallet link)
create or replace function public.card_token_for(p_customer uuid) returns uuid language plpgsql stable security definer set search_path to '' as $f$
begin
  if private.staff_role() is null then raise exception 'Only the team can do this.'; end if;
  return (select card_token from public.customers where id = p_customer);
end $f$;

-- the front desk scans a card: who is it
create or replace function public.card_find(p_token text) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare c record; t text := lower(btrim(coalesce(p_token, '')));
begin
  if private.staff_role() is null then raise exception 'Only the team can do this.'; end if;
  t := coalesce(substring(t from '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'), '');
  if t = '' then return null; end if;
  select id, name, email, phone into c from public.customers where card_token = t::uuid;
  if c.id is null then return null; end if;
  return jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone);
end $f$;

-- the wallet function (service only): everything the card shows
create or replace function public.card_data(p_token uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare c record; p record; today date := (now() at time zone private.tz())::date; s jsonb;
begin
  select id, name, card_token into c from public.customers where card_token = p_token;
  if c.id is null then return null; end if;
  select x.package_name, x.expires_on, x.visit_limit, x.visits_left, x.per_week_limit, x.starts_on into p
    from public.purchases x
    where x.customer_id = c.id and not x.cancelled and x.upgrade_done_at is null and (x.expires_on is null or x.expires_on >= today)
      and not ('Privates' = any(coalesce(x.covers, '{}')) and coalesce(array_length(x.covers, 1), 0) = 1)
    order by (x.starts_on is null or x.starts_on <= today) desc, x.expires_on desc nulls last, x.purchased_on desc limit 1;
  s := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'wallet_card'), '{}'::jsonb);
  return jsonb_build_object('name', c.name, 'token', c.card_token, 'biz', private.biz_main(), 'on', private.feature('wallet_card', true),
    'theme', coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'app_theme'), '{}'::jsonb),
    'settings', s, 'region', public.app_region(), 'today', today,
    'package', case when p.package_name is null then null else jsonb_build_object('name', p.package_name, 'until', p.expires_on, 'starts', p.starts_on,
      'left', case when p.visit_limit is null then null else coalesce(p.visits_left, p.visit_limit) end, 'week', p.per_week_limit) end,
    'updated', coalesce((select updated_at from public.wallet_updates where card_token = c.card_token), now()));
end $f$;

-- a package sold or changed, or a check in: mark the card as changed and tell the iPhones that saved it
create or replace function private.card_changed() returns trigger language plpgsql security definer set search_path to '' as $f$
declare cid uuid := coalesce(new.customer_id, old.customer_id); tok uuid; v_base text; v_key text;
begin
  if cid is null then return coalesce(new, old); end if;
  select card_token into tok from public.customers where id = cid;
  if tok is null or not exists (select 1 from public.wallet_devices where card_token = tok) then return coalesce(new, old); end if;
  insert into public.wallet_updates (card_token, updated_at) values (tok, now()) on conflict (card_token) do update set updated_at = now();
  begin
    select value into v_base from private.sync_settings where key = 'functions_url';
    select value into v_key from private.sync_settings where key = 'sync_token';
    if v_base is not null and v_key is not null then
      perform net.http_post(url := v_base || '/wallet?k=push', headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', v_key),
        body := jsonb_build_object('token', tok), timeout_milliseconds := 20000);
    end if;
  exception when others then null;
  end;
  return coalesce(new, old);
end $f$;
drop trigger if exists card_changed on public.purchases;
create trigger card_changed after insert or update on public.purchases for each row execute function private.card_changed();
drop trigger if exists card_changed on public.checkins;
create trigger card_changed after insert or delete on public.checkins for each row execute function private.card_changed();

revoke all on function public.my_card() from public, anon;
revoke all on function public.card_token_for(uuid) from public, anon;
revoke all on function public.card_find(text) from public, anon;
revoke all on function public.card_data(uuid) from public, anon, authenticated;
revoke all on function private.card_changed() from public, anon, authenticated;
grant execute on function public.my_card() to authenticated;
grant execute on function public.card_token_for(uuid) to authenticated;
grant execute on function public.card_find(text) to authenticated;
grant execute on function public.card_data(uuid) to service_role;

notify pgrst, 'reload schema';
