-- Receipts for customers: a private link to a receipt page (receipt.html?t=...) for a package, a private or a till sale.
-- The desk sends it by email, WhatsApp, LINE, a QR to scan, or copies the link. Feature switch: receipt_send.
-- Business details on the receipt (address, tax number, thank you line) live in app_settings key receipt_info.

create table if not exists public.receipt_links (
  token text primary key,
  kind text not null check (kind in ('purchase','private','shop')),
  ref uuid not null,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  sent jsonb not null default '[]'::jsonb,
  unique (kind, ref)
);
alter table public.receipt_links enable row level security;  -- only through the functions below

insert into public.app_settings (key, value) values ('receipt_info', '{}') on conflict (key) do nothing;

-- the desk: the link for one receipt (made once, then the same link)
create or replace function public.receipt_link(p_kind text, p_ref uuid) returns jsonb language plpgsql security definer set search_path to '' as $$
declare t text; cid uuid;
begin
  if not private.is_desk() then raise exception 'Only the desk can send receipts.'; end if;
  if p_kind = 'purchase' then select customer_id into cid from public.purchases where id = p_ref;
  elsif p_kind = 'private' then select customer_id into cid from public.privates where id = p_ref;
  elsif p_kind = 'shop' then select customer_id into cid from public.shop_orders where id = p_ref;
  else raise exception 'Unknown receipt.'; end if;
  if not found then raise exception 'That sale was not found.'; end if;
  select token into t from public.receipt_links where kind = p_kind and ref = p_ref;
  if t is null then
    t := replace(gen_random_uuid()::text, '-', '') || left(replace(gen_random_uuid()::text, '-', ''), 8);
    insert into public.receipt_links (token, kind, ref) values (t, p_kind, p_ref) on conflict (kind, ref) do nothing;
    select token into t from public.receipt_links where kind = p_kind and ref = p_ref;
  end if;
  return jsonb_build_object('token', t,
    'name', (select name from public.customers where id = cid), 'email', (select email from public.customers where id = cid), 'phone', (select phone from public.customers where id = cid));
end $$;

-- the desk: note how it was sent (shows on the receipt list later)
create or replace function public.receipt_sent(p_token text, p_how text, p_to text) returns void language plpgsql security definer set search_path to '' as $$
begin
  if not private.is_desk() then raise exception 'Only the desk can send receipts.'; end if;
  update public.receipt_links set sent = sent || jsonb_build_array(jsonb_build_object('how', left(p_how, 20), 'to', left(coalesce(p_to, ''), 120), 'at', now()))
  where token = p_token;
end $$;

-- anyone with the link: the receipt (no sign in; the long token is the key)
create or replace function public.receipt_view(p_token text) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare l public.receipt_links; r jsonb; info jsonb; we jsonb; th jsonb; pu public.purchases; pv public.privates; so public.shop_orders; cid uuid;
  lines jsonb := '[]'::jsonb; pays jsonb; tot int; fee int := 0; tax int := 0; disc int := 0; paid int; dt date; num text;
begin
  if p_token is null or length(p_token) < 24 then return null; end if;
  select * into l from public.receipt_links where token = p_token;
  if l.token is null then return null; end if;
  begin info := (select value::jsonb from public.app_settings where key = 'receipt_info'); exception when others then info := '{}'; end;
  begin we := (select value::jsonb from public.app_settings where key = 'welcome_email'); exception when others then we := '{}'; end;
  begin th := (select value::jsonb from public.app_settings where key = 'app_theme'); exception when others then th := '{}'; end;
  if l.kind = 'purchase' then
    select * into pu from public.purchases where id = l.ref; if pu.id is null then return null; end if;
    cid := pu.customer_id; fee := coalesce(pu.fee_thb, 0); tax := coalesce(pu.tax_thb, 0); tot := coalesce(pu.price_thb, 0); dt := pu.purchased_on;
    lines := jsonb_build_array(jsonb_build_object('name', pu.package_name, 'amount', tot - fee - tax));
    select coalesce(jsonb_agg(jsonb_build_object('amount', amount_thb, 'method', method, 'day', day) order by at), '[]') into pays from public.payments where purchase_id = pu.id and not coalesce(voided, false) and not coalesce(is_fee, false);
    paid := coalesce(pu.paid_thb, 0); num := 'P-' || upper(left(replace(pu.id::text, '-', ''), 8));
  elsif l.kind = 'private' then
    select * into pv from public.privates where id = l.ref; if pv.id is null then return null; end if;
    cid := pv.customer_id; fee := coalesce(pv.fee_thb, 0); tax := coalesce(pv.tax_thb, 0); dt := pv.date;
    tot := coalesce(pv.price_thb, 0) + coalesce(pv.extra_thb, 0);
    lines := jsonb_build_array(jsonb_build_object('name', 'Private session, ' || to_char(pv.date, 'FMDD Mon YYYY') || coalesce(' ' || left(pv.start_time::text, 5), '')
      || coalesce(' with ' || (select name from public.staff where id = pv.coach_id), ''), 'amount', coalesce(pv.price_thb, 0) - fee - tax));
    if coalesce(pv.extra_thb, 0) > 0 then lines := lines || jsonb_build_array(jsonb_build_object('name', 'Extra', 'amount', pv.extra_thb)); end if;
    select coalesce(jsonb_agg(jsonb_build_object('amount', amount_thb, 'method', method, 'day', day) order by at), '[]'), coalesce(sum(amount_thb), 0) into pays, paid
      from public.payments where private_id = pv.id and not coalesce(voided, false) and not coalesce(is_fee, false);
    if pv.purchase_id is not null then paid := tot; pays := jsonb_build_array(jsonb_build_object('amount', tot, 'method', 'pack', 'day', pv.date)); end if;
    num := 'S-' || upper(left(replace(pv.id::text, '-', ''), 8));
  else
    select * into so from public.shop_orders where id = l.ref; if so.id is null then return null; end if;
    cid := so.customer_id; fee := coalesce(so.fee_thb, 0); tax := coalesce(so.tax_thb, 0); disc := coalesce(so.discount_thb, 0); tot := coalesce(so.total_thb, 0);
    dt := (coalesce(so.paid_at, so.created_at) at time zone 'Asia/Bangkok')::date;
    select coalesce(jsonb_agg(jsonb_build_object('name', name || case when qty > 1 then ' x ' || qty else '' end, 'amount', price_thb * qty) order by id), '[]') into lines
      from public.shop_order_items where order_id = so.id and not coalesce(removed, false);
    paid := case when so.status in ('paid','refunded') or so.paid_at is not null then tot else 0 end;
    pays := case when paid > 0 then jsonb_build_array(jsonb_build_object('amount', tot, 'method', so.method, 'day', dt)) else '[]'::jsonb end;
    num := '#' || so.number::text;
  end if;
  -- tpl: the branded letter (Invoices, Template: logo, address, colour, numbers); biz_key picks the business in it
  return jsonb_build_object('biz_key', private.biz_main(), 'tpl', (select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'invoice_template'), 'business', private.biz_main(), 'address', info->>'address', 'tax_id', info->>'tax_id', 'footer', coalesce(nullif(info->>'footer', ''), 'Thank you.'),
    'email', coalesce(nullif(info->>'email', ''), we->>'reply_to'), 'whatsapp', we->>'whatsapp', 'accent', th->>'accent',
    'number', num, 'date', dt, 'customer', (select name from public.customers where id = cid),
    'lines', lines, 'discount', disc, 'fee', fee, 'tax', tax, 'total', tot, 'paid', least(paid, tot), 'owed', greatest(tot - paid, 0), 'payments', pays,
    'refunded', coalesce(pu.refunded_at, pv.refunded_at, so.refunded_at) is not null, 'room', l.kind = 'shop' and so.status = 'room');
end $$;

revoke all on function public.receipt_link(text, uuid) from public, anon;
revoke all on function public.receipt_sent(text, text, text) from public, anon;
grant execute on function public.receipt_link(text, uuid) to authenticated;
grant execute on function public.receipt_sent(text, text, text) to authenticated;
grant execute on function public.receipt_view(text) to anon, authenticated;
