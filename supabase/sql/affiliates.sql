-- Affiliates: people who send guests to the resort get a share of the room price.
-- Each affiliate has a code. A link with ?ref=<code> is remembered for 60 days on the website, and a stay booked
-- online with it is tagged to them. Staff can also tag a stay by hand (bookings by message or phone).
-- Commission = the affiliate's % of the room price (not extras), fixed on the stay when it is tagged.
-- It is "coming" until the guest's arrival, "earned" from then on, nothing if the stay is cancelled.
-- Payouts are recorded here and show in Accounts as money out.

create table if not exists public.affiliates (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z0-9][a-z0-9-]{1,29}$'),
  name text not null check (length(trim(name)) > 0),
  email text,
  phone text,
  customer_id uuid references public.customers(id) on delete set null,
  pct numeric not null default 10 check (pct >= 0 and pct <= 50),
  active boolean not null default true,
  note text,
  created_at timestamptz not null default now()
);
alter table public.affiliates enable row level security;
revoke all on public.affiliates from anon, authenticated;

create table if not exists public.affiliate_payouts (
  id uuid primary key default gen_random_uuid(),
  affiliate_id uuid not null references public.affiliates(id) on delete cascade,
  amount_thb integer not null check (amount_thb > 0),
  paid_on date not null default private.bkk_today(),
  method text not null default 'transfer',
  note text,
  voided boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.affiliate_payouts enable row level security;
revoke all on public.affiliate_payouts from anon, authenticated;

alter table public.stays add column if not exists affiliate_id uuid references public.affiliates(id) on delete set null;
alter table public.stays add column if not exists affiliate_pct numeric;

-- the % is fixed on the stay when it is tagged, so changing an affiliate's % later does not change old stays
create or replace function private.stay_affiliate_pct() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if new.affiliate_id is null then new.affiliate_pct := null;
  elsif tg_op = 'INSERT' or new.affiliate_id is distinct from old.affiliate_id or new.affiliate_pct is null then
    new.affiliate_pct := (select pct from public.affiliates where id = new.affiliate_id);
  end if;
  return new;
end $f$;
drop trigger if exists stays_affiliate_pct on public.stays;
create trigger stays_affiliate_pct before insert or update of affiliate_id on public.stays for each row execute function private.stay_affiliate_pct();

create or replace function private.aff_commission(s public.stays) returns integer language sql immutable set search_path='' as $f$
  select case when s.affiliate_id is null or s.status = 'cancelled' then 0 else round(coalesce(s.room_price_thb,0) * coalesce(s.affiliate_pct,0) / 100)::int end
$f$;

create or replace function private.aff_state(s public.stays) returns text language sql stable set search_path='' as $f$
  select case when s.status = 'cancelled' then 'cancelled' when s.status = 'booked' and s.check_in > private.bkk_today() then 'coming' else 'earned' end
$f$;

create or replace function private.aff_row(a public.affiliates, p_full boolean) returns jsonb language sql stable security definer set search_path='' as $f$
  select jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'email', a.email, 'phone', a.phone, 'customer_id', a.customer_id,
    'pct', a.pct, 'active', a.active, 'note', a.note,
    'earned', coalesce((select sum(private.aff_commission(s)) from public.stays s where s.affiliate_id = a.id and private.aff_state(s) = 'earned'),0),
    'coming', coalesce((select sum(private.aff_commission(s)) from public.stays s where s.affiliate_id = a.id and private.aff_state(s) = 'coming'),0),
    'paid', coalesce((select sum(amount_thb) from public.affiliate_payouts where affiliate_id = a.id and not voided),0),
    'stays', coalesce((select jsonb_agg(jsonb_build_object('id', s.id,
        'guest', case when p_full then c.name else split_part(coalesce(c.name,'Guest'),' ',1) end,
        'room', case when p_full then r.name end, 'from', s.check_in, 'to', s.check_out,
        'price', case when p_full then s.room_price_thb end, 'pct', s.affiliate_pct,
        'commission', private.aff_commission(s), 'state', private.aff_state(s)) order by s.check_in desc)
      from public.stays s left join public.customers c on c.id = s.customer_id left join public.rooms r on r.id = s.room_id
      where s.affiliate_id = a.id), '[]'::jsonb),
    'payouts', case when p_full then coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'amount', p.amount_thb, 'on', p.paid_on, 'method', p.method, 'note', p.note) order by p.paid_on desc)
      from public.affiliate_payouts p where p.affiliate_id = a.id and not p.voided), '[]'::jsonb)
      else coalesce((select jsonb_agg(jsonb_build_object('amount', p.amount_thb, 'on', p.paid_on) order by p.paid_on desc)
      from public.affiliate_payouts p where p.affiliate_id = a.id and not p.voided), '[]'::jsonb) end)
$f$;

-- front desk and managers: the list (desk needs it to tag a stay)
create or replace function public.affiliates_list() returns jsonb language plpgsql stable security definer set search_path='' as $f$
begin
  if not private.is_desk() then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(private.aff_row(a, true) order by a.active desc, a.name) from public.affiliates a), '[]'::jsonb);
end $f$;

create or replace function public.affiliate_save(p jsonb) returns uuid language plpgsql security definer set search_path='' as $f$
declare v_id uuid := nullif(p->>'id','')::uuid; v_code text; v_name text := trim(coalesce(p->>'name',''));
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change affiliates.'; end if;
  if v_name = '' then raise exception 'Type a name.'; end if;
  v_code := lower(regexp_replace(trim(coalesce(nullif(p->>'code',''), v_name)), '[^A-Za-z0-9]+', '-', 'g'));
  v_code := trim(both '-' from v_code);
  v_code := left(v_code, 30);
  if length(v_code) < 2 then raise exception 'The link code needs at least 2 letters or numbers.'; end if;
  if exists (select 1 from public.affiliates where code = v_code and id is distinct from v_id) then
    if nullif(p->>'code','') is not null then raise exception 'That link code is taken. Try another.'; end if;
    v_code := left(v_code, 26) || '-' || (floor(random()*900)+100)::int;
  end if;
  if v_id is null then
    insert into public.affiliates(code, name, email, phone, customer_id, pct, active, note)
    values (v_code, v_name, nullif(trim(p->>'email'),''), nullif(trim(p->>'phone'),''), nullif(p->>'customer_id','')::uuid,
            coalesce(nullif(p->>'pct','')::numeric, 10), coalesce((p->>'active')::boolean, true), nullif(trim(p->>'note'),''))
    returning id into v_id;
  else
    update public.affiliates set code = v_code, name = v_name, email = nullif(trim(p->>'email'),''), phone = nullif(trim(p->>'phone'),''),
      customer_id = nullif(p->>'customer_id','')::uuid, pct = coalesce(nullif(p->>'pct','')::numeric, pct),
      active = coalesce((p->>'active')::boolean, active), note = nullif(trim(p->>'note'),'')
    where id = v_id;
    if not found then raise exception 'Not found.'; end if;
  end if;
  return v_id;
end $f$;

create or replace function public.affiliate_pay(p_aff uuid, p_amount integer, p_method text, p_note text, p_on date default null) returns uuid language plpgsql security definer set search_path='' as $f$
declare v uuid;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can pay affiliates.'; end if;
  if not (p_amount > 0) then raise exception 'Type the amount.'; end if;
  insert into public.affiliate_payouts(affiliate_id, amount_thb, method, note, paid_on)
  values (p_aff, p_amount, coalesce(nullif(p_method,''),'transfer'), nullif(trim(p_note),''), coalesce(p_on, private.bkk_today())) returning id into v;
  return v;
end $f$;

create or replace function public.affiliate_payout_undo(p_id uuid) returns void language plpgsql security definer set search_path='' as $f$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  update public.affiliate_payouts set voided = true where id = p_id;
end $f$;

-- the affiliate's own view in the member app
create or replace function public.affiliate_mine() returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare a public.affiliates;
begin
  select af.* into a from public.affiliates af join public.customers c on c.id = af.customer_id
  where c.user_id = auth.uid() and af.active order by af.created_at limit 1;
  if not found then return null; end if;
  return private.aff_row(a, false);
end $f$;

-- the website booking tags the stay (service role only)
create or replace function public.affiliate_tag_stay(p_stay uuid, p_code text) returns boolean language plpgsql security definer set search_path='' as $f$
declare v uuid;
begin
  select id into v from public.affiliates where code = lower(trim(coalesce(p_code,''))) and active;
  if v is null then return false; end if;
  update public.stays set affiliate_id = v where id = p_stay and affiliate_id is null;
  return found;
end $f$;
revoke all on function public.affiliate_tag_stay(uuid, text) from public, anon, authenticated;

grant execute on function public.affiliates_list(), public.affiliate_save(jsonb), public.affiliate_pay(uuid,integer,text,text,date),
  public.affiliate_payout_undo(uuid), public.affiliate_mine() to authenticated;

-- payouts show in Accounts as money out
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('private.acc_lines(date,date)'::regprocedure);
  if position('affiliate_payouts' in d) > 0 then return; end if;
  n := replace(d, '  union all
  -- entered by hand, monthly bills', '  union all
  -- affiliate commission paid out
  select ap.paid_on, ''Pangea Resort'', ''Rooms'', ''out'', ''Affiliate: ''||coalesce(af.name,''affiliate''), ''Affiliate commission'', ap.method, ap.amount_thb::numeric, ''affiliate'', ap.id, null
  from public.affiliate_payouts ap left join public.affiliates af on af.id = ap.affiliate_id where not ap.voided and ap.paid_on between p_from and p_to
  union all
  -- entered by hand, monthly bills');
  if n = d then raise exception 'acc_lines not changed'; end if;
  execute n;
end $$;
