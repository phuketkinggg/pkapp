-- Accounts: "things to check" (possible duplicates and odd entries) and a private link for a Google Sheet.
-- The sheet pulls the data with IMPORTDATA from the accounts-feed function, so it updates by itself.

create or replace function private.acc_checks(p_from date, p_to date)
returns table(level text, kind text, d date, b text, what text, a numeric, ref uuid, why text)
language sql stable security definer set search_path = '' as $f$
  with r as (select * from public.expense_receipts where status <> 'removed' and day between p_from and p_to),
       e as (select * from public.acc_entries where not voided and day between p_from and p_to),
       p as (select p.*, c.name cname from public.payments p left join public.customers c on c.id = p.customer_id
             where not p.voided and p.method <> 'before_app' and p.day between p_from and p_to and p.amount_thb > 0)
  -- the same receipt twice: same amount, same supplier (or no supplier), within 3 days
  select 'check', 'Possible duplicate receipt', r1.day, r1.business, coalesce(r1.supplier,'Receipt') || coalesce(' (' || r1.note || ')',''), r1.amount_thb, r1.id,
         'Same amount ' || to_char(r1.amount_thb,'FM999,999,990') || ' THB as another receipt on ' || to_char(r2.day,'FMDD Mon') || coalesce(' from ' || r2.supplier,'')
  from r r1 join r r2 on r2.id <> r1.id and r2.amount_thb = r1.amount_thb and r1.amount_thb > 0 and abs(r2.day - r1.day) <= 3
    and coalesce(lower(r2.supplier),'') = coalesce(lower(r1.supplier),'') and (r2.created_at, r2.id) < (r1.created_at, r1.id)
  union all
  -- a bill or entry typed twice
  select 'check', 'Possible duplicate entry', e1.day, e1.business, coalesce(nullif(e1.party,''), e1.category), e1.amount, e1.id,
         'Same amount, category and day as another ' || case when e1.kind = 'in' then 'money in' else 'money out' end || ' entry'
  from e e1 join e e2 on e2.id <> e1.id and e2.kind = e1.kind and e2.amount = e1.amount and e2.day = e1.day and coalesce(e2.category,'') = coalesce(e1.category,'')
    and coalesce(e2.business,'') = coalesce(e1.business,'') and (e2.created_at, e2.id) < (e1.created_at, e1.id)
  union all
  -- a customer charged the same amount twice on the same day
  select 'check', 'Possible double payment', p1.day, 'Phuket King Gym', coalesce(p1.cname,'Customer') || coalesce(' (' || p1.note || ')',''), p1.amount_thb, p1.id,
         'Paid the same amount twice on the same day. Fine if they bought two things, check if not.'
  from p p1 join p p2 on p2.id <> p1.id and p2.customer_id = p1.customer_id and p2.amount_thb = p1.amount_thb and p2.day = p1.day
    and coalesce(p2.purchase_id::text, p2.stay_id::text, p2.private_id::text, '') = coalesce(p1.purchase_id::text, p1.stay_id::text, p1.private_id::text, '')
    and p2.id < p1.id
  union all
  select 'todo', 'Receipt with no amount', r.day, r.business, coalesce(r.supplier,'Receipt'), null, r.id, 'Not counted until it has an amount. Open Sort receipts.'
  from r where r.amount_thb is null
  union all
  select 'todo', 'Receipt not sorted', r.day, r.business, coalesce(r.supplier,'Receipt'), r.amount_thb, r.id, 'No category yet. Open Sort receipts.'
  from r where r.amount_thb is not null and coalesce(r.category,'') = ''
  union all
  select 'check', 'Receipt with no business or department', r.day, r.business, coalesce(r.supplier,'Receipt'), r.amount_thb, r.id, 'Choose which business and department it belongs to.'
  from r where r.amount_thb is not null and (coalesce(r.business,'') = '' or coalesce(r.department,'') = '')
  union all
  select 'check', 'Date in the future', x.day, x.business, x.what, x.amount, x.id, 'The date is after today. Check the date.'
  from (select day, business, coalesce(supplier,'Receipt') what, amount_thb amount, id from r union all select day, business, coalesce(nullif(party,''),category), amount, id from e) x
  where x.day > private.bkk_today()
  union all
  -- much bigger than usual for its category (over 3 times the typical amount, and over 5,000 THB)
  select 'check', 'Much bigger than usual', x.day, x.business, x.what || ' [' || x.cat || ']', x.amount, x.id,
         'Usually about ' || to_char(x.med,'FM999,999,990') || ' THB for ' || x.cat || '. Check for a typing mistake.'
  from (select y.*, percentile_cont(0.5) within group (order by y.amount) over (partition by y.cat) med, count(*) over (partition by y.cat) n
        from (select day, business, coalesce(supplier,'Receipt') what, coalesce(nullif(category,''),'Not sorted') cat, amount_thb amount, id from r where amount_thb > 0
              union all select day, business, coalesce(nullif(party,''),category), coalesce(category,'Other'), amount, id from e where kind = 'out' and amount > 0) y) x
  where x.n >= 4 and x.amount > 5000 and x.amount > 3 * x.med
$f$;

-- in the app, for managers
create or replace function public.acc_checks_list(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see the accounts.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('level',x.level,'kind',x.kind,'d',x.d,'b',x.b,'what',x.what,'a',x.a,'id',x.ref,'why',x.why) order by x.level, x.d desc)
    from private.acc_checks(p_from, p_to) x), '[]'::jsonb);
end $f$;

-- the private link for the Google Sheet
create or replace function public.acc_feed_link(p_new boolean default false) returns text
language plpgsql security definer set search_path = '' as $f$
declare t text;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select value into t from private.sync_settings where key = 'acc_feed_token';
  if t is null or p_new then
    t := encode(extensions.gen_random_bytes(18), 'hex');
    insert into private.sync_settings(key, value) values ('acc_feed_token', t) on conflict (key) do update set value = excluded.value;
  end if;
  return t;
end $f$;

-- what the feed function reads (service role only)
create or replace function public.acc_feed_data(p_token text, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare t text;
begin
  select value into t from private.sync_settings where key = 'acc_feed_token';
  if t is null or coalesce(p_token,'') <> t then return null; end if;
  return jsonb_build_object(
    'lines', coalesce((select jsonb_agg(jsonb_build_object('d',x.d,'b',x.b,'dep',x.dep,'t',x.t,'what',x.what,'cat',x.cat,'m',x.m,'a',x.a,'src',x.src,'id',x.ref,'to',x.to_b) order by x.d, x.src)
       from private.acc_lines(p_from, p_to) x), '[]'::jsonb),
    'checks', coalesce((select jsonb_agg(jsonb_build_object('level',x.level,'kind',x.kind,'d',x.d,'b',x.b,'what',x.what,'a',x.a,'id',x.ref,'why',x.why) order by x.level, x.d desc)
       from private.acc_checks(p_from, p_to) x), '[]'::jsonb));
end $f$;

revoke all on function public.acc_feed_data(text, date, date) from public, anon, authenticated;
grant execute on function public.acc_checks_list(date, date), public.acc_feed_link(boolean) to authenticated;
