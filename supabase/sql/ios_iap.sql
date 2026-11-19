-- Courses bought with Apple In-App Purchase in the iPhone and iPad app (feature ios_iap).
-- Each course can have an Apple product id (made in App Store Connect, In-App Purchases, Non-Consumable).
-- The app buys it with Apple, the function iap-apple checks Apple's signed receipt and calls iap_apple_grant,
-- which records the purchase (method agent: Apple collects the money and pays it out) and so unlocks the course on every device (web, Android and iPhone).
alter table public.courses add column if not exists apple_product_id text;
create unique index if not exists courses_apple_product_id on public.courses (apple_product_id) where apple_product_id is not null;

create table if not exists public.iap_apple (
  transaction_id text primary key,
  original_transaction_id text not null unique,
  customer_id uuid not null references public.customers(id) on delete cascade,
  course_id uuid references public.courses(id) on delete set null,
  product_id text not null,
  environment text not null,
  price numeric,
  currency text,
  purchase_id uuid,
  at timestamptz not null default now()
);
alter table public.iap_apple enable row level security;
revoke all on public.iap_apple from public, anon, authenticated;

-- for the app: which courses can be bought with Apple (only when the feature is on)
create or replace function public.course_apple_products() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when private.feature('ios_iap', false) then coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'product', c.apple_product_id))
    from public.courses c where c.apple_product_id is not null and c.status = 'published'), '[]'::jsonb) else '[]'::jsonb end
$f$;
revoke all on function public.course_apple_products() from public;
grant execute on function public.course_apple_products() to anon, authenticated;

-- called only by the iap-apple function, after it has checked Apple's signature. p: the transaction from Apple
-- (productId, transactionId, originalTransactionId, appAccountToken, environment, price, currency).
create or replace function public.iap_apple_grant(p_user uuid, p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare cid uuid; c public.courses; x public.iap_apple; pid uuid; thb int; tok text := nullif(p->>'appAccountToken', '');
begin
  if not private.feature('ios_iap', false) then raise exception 'Buying with Apple is not switched on.'; end if;
  select id into cid from public.customers where user_id = p_user order by created_at limit 1;
  if cid is null then raise exception 'Sign in to your account first.'; end if;
  if tok is not null and lower(tok) <> cid::text then raise exception 'This purchase belongs to another account.'; end if;
  select * into c from public.courses where apple_product_id = p->>'productId';
  if c.id is null then raise exception 'This course is not sold in the app any more.'; end if;
  select * into x from public.iap_apple where original_transaction_id = p->>'originalTransactionId';
  if x.transaction_id is not null then
    if x.customer_id <> cid then raise exception 'This purchase belongs to another account.'; end if;
    insert into public.course_access (customer_id, course_id, source) values (cid, c.id, 'bought') on conflict do nothing;
    return jsonb_build_object('ok', true, 'course_id', c.id, 'again', true);
  end if;
  -- the price the person paid, in baht when Apple charged baht; else the course price (Apple pays out in baht)
  thb := case when upper(coalesce(p->>'currency', '')) = 'THB' and (p->>'price') ~ '^[0-9]+$' then round((p->>'price')::numeric / 1000) else coalesce(c.price_thb, 0) end;
  insert into public.purchases (customer_id, package_name, price_thb, paid, paid_thb, method, course_id, purchased_on, fee_thb, ordered_in_app, covers)
    values (cid, 'Online course: ' || c.title || ' (App Store)', thb, true, thb, 'agent', c.id, (now() at time zone 'Asia/Bangkok')::date, round(thb * 0.15), true, '{}')
    returning id into pid;
  insert into public.course_access (customer_id, course_id, source) values (cid, c.id, 'bought') on conflict do nothing;
  insert into public.iap_apple (transaction_id, original_transaction_id, customer_id, course_id, product_id, environment, price, currency, purchase_id)
    values (p->>'transactionId', p->>'originalTransactionId', cid, c.id, p->>'productId', coalesce(p->>'environment', ''),
      case when (p->>'price') ~ '^[0-9]+$' then (p->>'price')::numeric / 1000 end, p->>'currency', pid);
  return jsonb_build_object('ok', true, 'course_id', c.id);
end $f$;
revoke all on function public.iap_apple_grant(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.iap_apple_grant(uuid, jsonb) to service_role;

-- Apple refunds: the function marks the purchase refunded and takes the course away (called with a revoked transaction)
create or replace function public.iap_apple_revoke(p jsonb) returns void language plpgsql security definer set search_path to '' as $f$
declare x public.iap_apple;
begin
  select * into x from public.iap_apple where original_transaction_id = p->>'originalTransactionId';
  if x.transaction_id is null then return; end if;
  update public.purchases set refunded_at = now(), refund_thb = price_thb, refund_reason = 'Refunded by Apple' where id = x.purchase_id and refunded_at is null;
  delete from public.course_access where customer_id = x.customer_id and course_id = x.course_id and source = 'bought'
    and not exists (select 1 from public.purchases pu where pu.customer_id = x.customer_id and pu.course_id = x.course_id and pu.id <> x.purchase_id and pu.refunded_at is null and not coalesce(pu.cancelled, false));
end $f$;
revoke all on function public.iap_apple_revoke(jsonb) from public, anon, authenticated;
grant execute on function public.iap_apple_revoke(jsonb) to service_role;

notify pgrst, 'reload schema';

-- managers: set a course's Apple product id, and see them all (for the course form)
create or replace function public.course_apple_set(p_course uuid, p_product text) returns void language plpgsql security definer set search_path to '' as $f$
declare v text := nullif(btrim(coalesce(p_product, '')), '');
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  if v is not null and v !~ '^[A-Za-z0-9._-]{1,100}$' then raise exception 'The Apple product id can only have letters, numbers, dots, dashes and underscores.'; end if;
  if v is not null and exists (select 1 from public.courses where apple_product_id = v and id <> p_course) then raise exception 'Another course already has that Apple product id.'; end if;
  update public.courses set apple_product_id = v where id = p_course;
end $f$;
create or replace function public.course_apple_ids() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when coalesce(private.staff_role(), '') = 'manager' then coalesce((select jsonb_object_agg(id, apple_product_id) from public.courses where apple_product_id is not null), '{}'::jsonb) else '{}'::jsonb end
$f$;
revoke all on function public.course_apple_set(uuid, text), public.course_apple_ids() from public, anon;
grant execute on function public.course_apple_set(uuid, text), public.course_apple_ids() to authenticated;
notify pgrst, 'reload schema';
