-- Invoices: a deposit to pay now and the balance by a date.
-- Status goes unpaid -> deposit_paid -> paid. Each part gets its own receipt number and its own money in line in Accounts.

alter table public.invoices add column if not exists deposit numeric not null default 0;
alter table public.invoices add column if not exists balance_due date;
alter table public.invoices add column if not exists deposit_paid_on date;
alter table public.invoices add column if not exists deposit_method text;
alter table public.invoices add column if not exists deposit_note text;
alter table public.invoices add column if not exists deposit_receipt integer unique;
alter table public.invoices add column if not exists deposit_acc_entry uuid;
alter table public.invoices add column if not exists deposit_session text;
alter table public.invoices drop constraint if exists invoices_status_check;
alter table public.invoices add constraint invoices_status_check check (status in ('unpaid','deposit_paid','paid','cancelled'));

-- what is to pay now
create or replace function private.invoice_due_now(i public.invoices) returns numeric language sql immutable set search_path = '' as $f$
  select case when i.status = 'unpaid' and i.deposit > 0 then i.deposit
              when i.status in ('unpaid','deposit_paid') then i.total - case when i.deposit_paid_on is not null then i.deposit else 0 end
              else 0 end
$f$;

create or replace function private.inv_json(i public.invoices) returns jsonb language sql stable set search_path = '' as $f$
  select to_jsonb(i) - 'created_by' - 'stripe_session' - 'deposit_session' || jsonb_build_object('due_now', private.invoice_due_now(i))
$f$;

-- save: deposit and balance date
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.invoice_save(jsonb)'::regprocedure);
  if position('balance_due' in d) > 0 then return; end if;
  n := replace(d, 'if coalesce((p->>''pay_card'')::boolean,false) and tot < 20 then raise exception ''Card payments need at least 20 THB.''; end if;',
'if coalesce((p->>''pay_card'')::boolean,false) and tot < 20 then raise exception ''Card payments need at least 20 THB.''; end if;
  dep := round(greatest(0, coalesce(nullif(p->>''deposit'','''')::numeric, 0)), 2);
  if dep > 0 and dep >= tot then raise exception ''The deposit must be less than the total.''; end if;
  if dep > 0 and coalesce((p->>''pay_card'')::boolean,false) and dep < 20 then raise exception ''Card payments need at least 20 THB. Make the deposit bigger.''; end if;
  if dep > 0 and nullif(p->>''balance_due'','''') is null then raise exception ''Choose the date the balance is to be paid by.''; end if;');
  n := replace(n, 'if o.status = ''paid'' then raise exception ''This invoice is paid. Mark it not paid first to change it.''; end if;',
                  'if o.status in (''paid'',''deposit_paid'') then raise exception ''This invoice has a payment on it. Mark it not paid first to change it.''; end if;');
  n := replace(n, 'pay_promptpay = coalesce((p->>''pay_promptpay'')::boolean,false),',
                  'pay_promptpay = coalesce((p->>''pay_promptpay'')::boolean,false), deposit = dep, balance_due = case when dep > 0 then nullif(p->>''balance_due'','''')::date end,');
  n := replace(n, 'v numeric; tot numeric; n integer;', 'v numeric; tot numeric; n integer; dep numeric;');
  if position('dep numeric' in n) = 0 or position('deposit = dep' in n) = 0 then raise exception 'invoice_save not changed'; end if;
  execute n;
end $$;

-- take a payment: the deposit first (when there is one), then the rest. p_whole pays everything left in one go.
create or replace function private.invoice_pay(p_id uuid, p_whole boolean, p_method text, p_on date, p_note text, p_session text) returns public.invoices
language plpgsql security definer set search_path = '' as $f$
declare o public.invoices; n integer; e uuid; amt numeric; m text := coalesce(p_method,'transfer'); d date := coalesce(p_on, private.bkk_today());
begin
  select * into o from public.invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if o.status = 'paid' then return o; end if;
  if o.status = 'cancelled' then raise exception 'This invoice is cancelled.'; end if;
  select greatest(coalesce(max(receipt_number),0), coalesce(max(deposit_receipt),0)) + 1 into n from public.invoices;
  if o.status = 'unpaid' and o.deposit > 0 and not coalesce(p_whole,false) then
    insert into public.acc_entries(kind, day, business, department, category, amount, method, party, note)
    values ('in', d, o.business, o.department, 'Invoice', o.deposit, m, coalesce(o.to_company, o.to_name), 'Invoice ' || lpad(o.number::text, 4, '0') || ' deposit')
    returning id into e;
    update public.invoices set status = 'deposit_paid', deposit_paid_on = d, deposit_method = m, deposit_note = nullif(trim(p_note),''),
      deposit_receipt = n, deposit_acc_entry = e, deposit_session = p_session, updated_at = now()
    where id = p_id returning * into o;
    return o;
  end if;
  amt := o.total - case when o.deposit_paid_on is not null then o.deposit else 0 end;
  insert into public.acc_entries(kind, day, business, department, category, amount, method, party, note)
  values ('in', d, o.business, o.department, 'Invoice', amt, m, coalesce(o.to_company, o.to_name),
          'Invoice ' || lpad(o.number::text, 4, '0') || case when o.deposit_paid_on is not null then ' balance' else '' end)
  returning id into e;
  update public.invoices set status = 'paid', paid_on = d, paid_method = m, paid_note = nullif(trim(p_note),''),
    receipt_number = n, acc_entry_id = e, stripe_session = coalesce(p_session, stripe_session), updated_at = now()
  where id = p_id returning * into o;
  return o;
end $f$;

-- the Stripe webhook keeps calling this one: it pays the next part
create or replace function private.invoice_set_paid(p_id uuid, p_method text, p_on date, p_note text, p_session text) returns public.invoices
language sql security definer set search_path = '' as $f$
  select private.invoice_pay(p_id, false, p_method, p_on, p_note, p_session)
$f$;

drop function if exists public.invoice_paid(uuid, text, date, text);
create or replace function public.invoice_paid(p_id uuid, p_method text, p_on date, p_note text, p_whole boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  if p_method not in ('transfer','cash','card','qr','stripe','cheque','other') then raise exception 'Choose how it was paid.'; end if;
  return private.inv_json(private.invoice_pay(p_id, p_whole, p_method, p_on, p_note, null));
end $f$;

create or replace function public.invoice_unpaid(p_id uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare o public.invoices;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select * into o from public.invoices where id = p_id for update;
  update public.acc_entries set voided = true where id in (o.acc_entry_id, o.deposit_acc_entry);
  update public.invoices set status = 'unpaid', paid_on = null, paid_method = null, paid_note = null, receipt_number = null, acc_entry_id = null,
    deposit_paid_on = null, deposit_method = null, deposit_note = null, deposit_receipt = null, deposit_acc_entry = null, deposit_session = null, updated_at = now()
  where id = p_id returning * into o;
  return private.inv_json(o);
end $f$;

create or replace function public.invoice_cancel(p_id uuid) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare o public.invoices;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select * into o from public.invoices where id = p_id;
  if o.status in ('paid','deposit_paid') then raise exception 'Mark it not paid first.'; end if;
  update public.invoices set status = 'cancelled', updated_at = now() where id = p_id returning * into o;
  return private.inv_json(o);
end $f$;

grant execute on function public.invoice_paid(uuid,text,date,text,boolean), public.invoice_unpaid(uuid), public.invoice_cancel(uuid) to authenticated;

-- Stripe: a deposit and a balance are two card payments
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.stripe_record(text,text,uuid,integer,text)'::regprocedure);
  if position('deposit_session' in d) > 0 then return; end if;
  n := replace(d, 'if exists (select 1 from public.invoices where stripe_session = p_session) then', 'if exists (select 1 from public.invoices where p_session in (stripe_session, deposit_session)) then');
  if n = d then raise exception 'stripe_record not changed'; end if;
  execute n;
end $$;
