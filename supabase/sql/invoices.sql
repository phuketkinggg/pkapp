-- Invoices and receipts.
-- Numbers count up by themselves (INV-0001, then RC-0001 for the receipt when it is paid).
-- Payment can be offered by bank transfer, card (Stripe) and PromptPay QR, any mix.
-- When an invoice is paid it shows in Accounts as money in (an acc_entries line), and a receipt number is given.
-- The look (logo, company details, bank account) is app_settings 'invoice_template'.

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique,
  business text not null default 'Phuket King Gym',
  department text,
  to_name text not null,
  to_company text,
  to_tax_id text,
  to_address text,
  to_email text,
  to_phone text,
  customer_id uuid references public.customers(id) on delete set null,
  issue_date date not null default private.bkk_today(),
  due_date date,
  items jsonb not null default '[]'::jsonb,
  discount numeric not null default 0,
  vat_rate numeric not null default 0,
  subtotal numeric not null default 0,
  vat numeric not null default 0,
  total numeric not null default 0,
  notes text,
  pay_bank boolean not null default true,
  pay_card boolean not null default false,
  pay_promptpay boolean not null default false,
  status text not null default 'unpaid' check (status in ('unpaid','paid','cancelled')),
  paid_on date,
  paid_method text,
  paid_note text,
  receipt_number integer unique,
  acc_entry_id uuid,
  stripe_session text,
  token text not null unique default encode(extensions.gen_random_bytes(12), 'hex'),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.invoices enable row level security;
revoke all on public.invoices from anon, authenticated;

insert into public.app_settings(key, value) values ('invoice_template', '{}') on conflict (key) do nothing;

create or replace function private.inv_json(i public.invoices) returns jsonb language sql stable set search_path = '' as $f$
  select to_jsonb(i) - 'created_by' - 'stripe_session'
$f$;

create or replace function public.invoices_list() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see invoices.'; end if;
  return coalesce((select jsonb_agg(private.inv_json(i) order by i.number desc) from (select * from public.invoices order by number desc limit 1000) i), '[]'::jsonb);
end $f$;

create or replace function public.invoice_save(p jsonb) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_id uuid := nullif(p->>'id','')::uuid; o public.invoices; it jsonb; items jsonb := '[]'::jsonb; sub numeric := 0; q numeric; pr numeric;
  disc numeric := greatest(0, coalesce(nullif(p->>'discount','')::numeric, 0)); rate numeric := coalesce(nullif(p->>'vat_rate','')::numeric, 0); v numeric; tot numeric; n integer;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can make invoices.'; end if;
  if trim(coalesce(p->>'to_name','')) = '' and trim(coalesce(p->>'to_company','')) = '' then raise exception 'Type who the invoice is for.'; end if;
  if rate not in (0, 7) then raise exception 'VAT is 0 or 7 percent.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items','[]'::jsonb)) loop
    if trim(coalesce(it->>'desc','')) = '' then continue; end if;
    q := coalesce(nullif(it->>'qty','')::numeric, 1); pr := coalesce(nullif(it->>'price','')::numeric, 0);
    if q <= 0 then raise exception 'Each line needs a quantity above 0.'; end if;
    items := items || jsonb_build_array(jsonb_build_object('desc', left(trim(it->>'desc'), 300), 'qty', q, 'price', round(pr, 2), 'amount', round(q * pr, 2)));
    sub := sub + round(q * pr, 2);
  end loop;
  if jsonb_array_length(items) = 0 then raise exception 'Add at least one line.'; end if;
  if disc > sub then raise exception 'The discount is more than the total.'; end if;
  v := round((sub - disc) * rate / 100, 2); tot := sub - disc + v;
  if not (coalesce((p->>'pay_bank')::boolean,false) or coalesce((p->>'pay_card')::boolean,false) or coalesce((p->>'pay_promptpay')::boolean,false)) then
    raise exception 'Choose at least one way to pay.'; end if;
  if coalesce((p->>'pay_card')::boolean,false) and tot < 20 then raise exception 'Card payments need at least 20 THB.'; end if;
  if v_id is null then
    lock table public.invoices in share row exclusive mode;
    select coalesce(max(number), 0) + 1 into n from public.invoices;
    insert into public.invoices(number, to_name) values (n, '') returning * into o; v_id := o.id;
  else
    select * into o from public.invoices where id = v_id for update;
    if not found then raise exception 'Invoice not found.'; end if;
    if o.status = 'paid' then raise exception 'This invoice is paid. Mark it not paid first to change it.'; end if;
  end if;
  update public.invoices set
    business = coalesce(nullif(p->>'business',''), 'Phuket King Gym'), department = nullif(p->>'department',''),
    to_name = trim(coalesce(nullif(p->>'to_name',''), p->>'to_company')), to_company = nullif(trim(p->>'to_company'),''), to_tax_id = nullif(trim(p->>'to_tax_id'),''),
    to_address = nullif(trim(p->>'to_address'),''), to_email = nullif(lower(trim(p->>'to_email')),''), to_phone = nullif(trim(p->>'to_phone'),''),
    customer_id = nullif(p->>'customer_id','')::uuid,
    issue_date = coalesce(nullif(p->>'issue_date','')::date, private.bkk_today()), due_date = nullif(p->>'due_date','')::date,
    items = items, discount = disc, vat_rate = rate, subtotal = sub, vat = v, total = tot, notes = nullif(trim(p->>'notes'),''),
    pay_bank = coalesce((p->>'pay_bank')::boolean,false), pay_card = coalesce((p->>'pay_card')::boolean,false), pay_promptpay = coalesce((p->>'pay_promptpay')::boolean,false),
    status = case when status = 'cancelled' then 'unpaid' else status end, updated_at = now()
  where id = v_id returning * into o;
  return private.inv_json(o);
end $f$;

-- paid: a receipt number, and money in for Accounts
create or replace function private.invoice_set_paid(p_id uuid, p_method text, p_on date, p_note text, p_session text) returns public.invoices
language plpgsql security definer set search_path = '' as $f$
declare o public.invoices; n integer; e uuid;
begin
  select * into o from public.invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if o.status = 'paid' then return o; end if;
  if o.status = 'cancelled' then raise exception 'This invoice is cancelled.'; end if;
  select coalesce(max(receipt_number), 0) + 1 into n from public.invoices;
  insert into public.acc_entries(kind, day, business, department, category, amount, method, party, note)
  values ('in', coalesce(p_on, private.bkk_today()), o.business, o.department, 'Invoice', o.total, coalesce(p_method,'transfer'),
          coalesce(o.to_company, o.to_name), 'Invoice ' || lpad(o.number::text, 4, '0'))
  returning id into e;
  update public.invoices set status = 'paid', paid_on = coalesce(p_on, private.bkk_today()), paid_method = coalesce(p_method,'transfer'), paid_note = nullif(trim(p_note),''),
    receipt_number = n, acc_entry_id = e, stripe_session = coalesce(p_session, stripe_session), updated_at = now()
  where id = p_id returning * into o;
  return o;
end $f$;

create or replace function public.invoice_paid(p_id uuid, p_method text, p_on date, p_note text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if p_method not in ('transfer','cash','card','qr','stripe','cheque','other') then raise exception 'Choose how it was paid.'; end if;
  return private.inv_json(private.invoice_set_paid(p_id, p_method, p_on, p_note, null));
end $f$;

create or replace function public.invoice_unpaid(p_id uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare o public.invoices;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select * into o from public.invoices where id = p_id for update;
  if o.acc_entry_id is not null then update public.acc_entries set voided = true where id = o.acc_entry_id; end if;
  update public.invoices set status = 'unpaid', paid_on = null, paid_method = null, paid_note = null, receipt_number = null, acc_entry_id = null, updated_at = now()
  where id = p_id returning * into o;
  return private.inv_json(o);
end $f$;

create or replace function public.invoice_cancel(p_id uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare o public.invoices;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select * into o from public.invoices where id = p_id;
  if o.status = 'paid' then raise exception 'Mark it not paid first.'; end if;
  update public.invoices set status = 'cancelled', updated_at = now() where id = p_id returning * into o;
  return private.inv_json(o);
end $f$;

-- the customer's page (through the invoice function, service role only)
create or replace function public.invoice_public(p_token text) returns jsonb language sql stable security definer set search_path = '' as $f$
  select jsonb_build_object('invoice', private.inv_json(i) - 'acc_entry_id' - 'customer_id',
    'template', coalesce((select value::jsonb from public.app_settings where key = 'invoice_template'), '{}'::jsonb),
    'promptpay', (select jsonb_build_object('payload', payload, 'name', name) from public.promptpay_accounts where payload is not null order by location_id nulls first limit 1))
  from public.invoices i where i.token = p_token and i.status <> 'cancelled'
$f$;
revoke all on function public.invoice_public(text) from public, anon, authenticated;
grant execute on function public.invoices_list(), public.invoice_save(jsonb), public.invoice_paid(uuid,text,date,text), public.invoice_unpaid(uuid), public.invoice_cancel(uuid) to authenticated;

-- card payments come back through the Stripe webhook
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.stripe_record(text,text,uuid,integer,text)'::regprocedure);
  if position('''invoice''' in d) > 0 then return; end if;
  n := replace(d, '  elsif p_kind = ''webpkg'' then', '  elsif p_kind = ''invoice'' then
    if exists (select 1 from public.invoices where stripe_session = p_session) then return jsonb_build_object(''already'', true); end if;
    perform private.invoice_set_paid(p_id, ''stripe'', private.bkk_today(), ''Paid online by card'', p_session);
  elsif p_kind = ''webpkg'' then');
  if n = d then raise exception 'stripe_record not changed'; end if;
  execute n;
end $$;
