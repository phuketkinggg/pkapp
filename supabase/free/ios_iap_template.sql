delete from mf.template where name like 'ios_iap:%';
insert into mf.template (ord, phase, kind, name, sql) values (303561, 3, 'patch', 'ios_iap:303561', $TPL$alter table __P__.courses add column if not exists apple_product_id text;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002261, 10, 'patch', 'ios_iap:1002261', $TPL$create unique index if not exists courses_apple_product_id on __P__.courses (apple_product_id) where apple_product_id is not null;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303562, 3, 'patch', 'ios_iap:303562', $TPL$create table if not exists __P__.iap_apple (
  transaction_id text primary key,
  original_transaction_id text not null unique,
  customer_id uuid not null references __P__.customers(id) on delete cascade,
  course_id uuid references __P__.courses(id) on delete set null,
  product_id text not null,
  environment text not null,
  price numeric,
  currency text,
  purchase_id uuid,
  at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303563, 3, 'patch', 'ios_iap:303563', $TPL$alter table __P__.iap_apple enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197741, 11, 'patch', 'ios_iap:1197741', $TPL$revoke all on __P__.iap_apple from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403741, 4, 'patch', 'ios_iap:403741', $TPL$create or replace function __P__.course_apple_products() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when __Q__.feature('ios_iap', false) then coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'product', c.apple_product_id))
    from __P__.courses c where c.apple_product_id is not null and c.status = 'published'), '[]'::jsonb) else '[]'::jsonb end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197742, 11, 'patch', 'ios_iap:1197742', $TPL$revoke all on function __P__.course_apple_products() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197743, 11, 'patch', 'ios_iap:1197743', $TPL$grant execute on function __P__.course_apple_products() to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403742, 4, 'patch', 'ios_iap:403742', $TPL$create or replace function __P__.iap_apple_grant(p_user uuid, p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare cid uuid; c __P__.courses; x __P__.iap_apple; pid uuid; thb int; tok text := nullif(p->>'appAccountToken', '');
begin
  if not __Q__.feature('ios_iap', false) then raise exception 'Buying with Apple is not switched on.'; end if;
  select id into cid from __P__.customers where user_id = p_user order by created_at limit 1;
  if cid is null then raise exception 'Sign in to your account first.'; end if;
  if tok is not null and lower(tok) <> cid::text then raise exception 'This purchase belongs to another account.'; end if;
  select * into c from __P__.courses where apple_product_id = p->>'productId';
  if c.id is null then raise exception 'This course is not sold in the app any more.'; end if;
  select * into x from __P__.iap_apple where original_transaction_id = p->>'originalTransactionId';
  if x.transaction_id is not null then
    if x.customer_id <> cid then raise exception 'This purchase belongs to another account.'; end if;
    insert into __P__.course_access (customer_id, course_id, source) values (cid, c.id, 'bought') on conflict do nothing;
    return jsonb_build_object('ok', true, 'course_id', c.id, 'again', true);
  end if;
  -- the price the person paid, in baht when Apple charged baht; else the course price (Apple pays out in baht)
  thb := case when upper(coalesce(p->>'currency', '')) = 'THB' and (p->>'price') ~ '^[0-9]+$' then round((p->>'price')::numeric / 1000) else coalesce(c.price_thb, 0) end;
  insert into __P__.purchases (customer_id, package_name, price_thb, paid, paid_thb, method, course_id, purchased_on, fee_thb, ordered_in_app, covers)
    values (cid, 'Online course: ' || c.title || ' (App Store)', thb, true, thb, 'agent', c.id, (now() at time zone 'Asia/Bangkok')::date, round(thb * 0.15), true, '{}')
    returning id into pid;
  insert into __P__.course_access (customer_id, course_id, source) values (cid, c.id, 'bought') on conflict do nothing;
  insert into __P__.iap_apple (transaction_id, original_transaction_id, customer_id, course_id, product_id, environment, price, currency, purchase_id)
    values (p->>'transactionId', p->>'originalTransactionId', cid, c.id, p->>'productId', coalesce(p->>'environment', ''),
      case when (p->>'price') ~ '^[0-9]+$' then (p->>'price')::numeric / 1000 end, p->>'currency', pid);
  return jsonb_build_object('ok', true, 'course_id', c.id);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197744, 11, 'patch', 'ios_iap:1197744', $TPL$revoke all on function __P__.iap_apple_grant(uuid, jsonb) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197745, 11, 'patch', 'ios_iap:1197745', $TPL$grant execute on function __P__.iap_apple_grant(uuid, jsonb) to service_role;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403743, 4, 'patch', 'ios_iap:403743', $TPL$create or replace function __P__.iap_apple_revoke(p jsonb) returns void language plpgsql security definer set search_path to '' as $f$
declare x __P__.iap_apple;
begin
  select * into x from __P__.iap_apple where original_transaction_id = p->>'originalTransactionId';
  if x.transaction_id is null then return; end if;
  update __P__.purchases set refunded_at = now(), refund_thb = price_thb, refund_reason = 'Refunded by Apple' where id = x.purchase_id and refunded_at is null;
  delete from __P__.course_access where customer_id = x.customer_id and course_id = x.course_id and source = 'bought'
    and not exists (select 1 from __P__.purchases pu where pu.customer_id = x.customer_id and pu.course_id = x.course_id and pu.id <> x.purchase_id and pu.refunded_at is null and not coalesce(pu.cancelled, false));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197746, 11, 'patch', 'ios_iap:1197746', $TPL$revoke all on function __P__.iap_apple_revoke(jsonb) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197747, 11, 'patch', 'ios_iap:1197747', $TPL$grant execute on function __P__.iap_apple_revoke(jsonb) to service_role;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403744, 4, 'patch', 'ios_iap:403744', $TPL$create or replace function __P__.course_apple_set(p_course uuid, p_product text) returns void language plpgsql security definer set search_path to '' as $f$
declare v text := nullif(btrim(coalesce(p_product, '')), '');
begin
  if coalesce(__Q__.staff_role(), '') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  if v is not null and v !~ '^[A-Za-z0-9._-]{1,100}$' then raise exception 'The Apple product id can only have letters, numbers, dots, dashes and underscores.'; end if;
  if v is not null and exists (select 1 from __P__.courses where apple_product_id = v and id <> p_course) then raise exception 'Another course already has that Apple product id.'; end if;
  update __P__.courses set apple_product_id = v where id = p_course;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403745, 4, 'patch', 'ios_iap:403745', $TPL$create or replace function __P__.course_apple_ids() returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when coalesce(__Q__.staff_role(), '') = 'manager' then coalesce((select jsonb_object_agg(id, apple_product_id) from __P__.courses where apple_product_id is not null), '{}'::jsonb) else '{}'::jsonb end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197748, 11, 'patch', 'ios_iap:1197748', $TPL$revoke all on function __P__.course_apple_set(uuid, text), __P__.course_apple_ids() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197749, 11, 'patch', 'ios_iap:1197749', $TPL$grant execute on function __P__.course_apple_set(uuid, text), __P__.course_apple_ids() to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'ios_iap:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
