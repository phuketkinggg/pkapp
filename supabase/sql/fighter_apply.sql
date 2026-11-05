-- Fighter applications (feature fighter_apply): people apply on the website Fighters page to fight for the gym.
-- The manager sees them in Customers, Fighters, and accepts (the person becomes a customer marked as a fighter, paying) or declines.
create table if not exists public.fighter_applications (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  phone text,
  country text,
  age int,
  weight text,
  record text,
  experience text,
  links text,
  followers int,
  arrive date,
  months int,
  goals text,
  status text not null default 'new' check (status in ('new','accepted','declined')),
  note text,
  customer_id uuid references public.customers(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.fighter_applications enable row level security;

create or replace function public.fighter_apply(p jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare v_name text := btrim(coalesce(p->>'name','')); v_email text := lower(btrim(coalesce(p->>'email',''))); v_id uuid; t text;
  num int := nullif(regexp_replace(coalesce(p->>'followers',''), '[^0-9]', '', 'g'), '')::numeric::int;
begin
  if not private.feature('fighter_apply', true) then raise exception 'Applications are closed right now. Message us on WhatsApp.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 80 then raise exception 'Type your full name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 120 then raise exception 'Type a real email address.'; end if;
  if (select count(*) from public.fighter_applications where email = v_email and created_at > now() - interval '1 day') >= 2
     or (select count(*) from public.fighter_applications where created_at > now() - interval '1 hour') >= 20 then
    raise exception 'We already have your application. We will be in touch.'; end if;
  t := nullif(btrim(coalesce(p->>'arrive','')), '');
  insert into public.fighter_applications (name, email, phone, country, age, weight, record, experience, links, followers, arrive, months, goals)
  values (v_name, v_email, left(nullif(btrim(coalesce(p->>'phone','')),''),40), left(nullif(btrim(coalesce(p->>'country','')),''),60),
    case when coalesce(p->>'age','') ~ '^[0-9]{1,2}$' then (p->>'age')::int end, left(nullif(btrim(coalesce(p->>'weight','')),''),40),
    left(nullif(btrim(coalesce(p->>'record','')),''),200), left(nullif(btrim(coalesce(p->>'experience','')),''),1500), left(nullif(btrim(coalesce(p->>'links','')),''),600),
    case when num between 0 and 1000000000 then num end,
    case when t ~ '^\d{4}-\d{2}-\d{2}$' then t::date end,
    case when coalesce(p->>'months','') ~ '^[0-9]{1,2}$' then (p->>'months')::int end,
    left(nullif(btrim(coalesce(p->>'goals','')),''),1500))
  returning id into v_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.fighter_apps() returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see fighter applications.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(a) order by (a.status = 'new') desc, a.created_at desc) from (select * from public.fighter_applications order by created_at desc limit 100) a), '[]'::jsonb);
end $$;

-- accept: the person becomes a customer marked as a fighter (paying their first month), or decline
create or replace function public.fighter_app_decide(p_id uuid, p_ok boolean, p_note text default null) returns uuid
language plpgsql security definer set search_path to '' as $$
declare a public.fighter_applications%rowtype; cid uuid;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select * into a from public.fighter_applications where id = p_id for update;
  if a.id is null then raise exception 'That application is not there any more.'; end if;
  if p_ok then
    select id into cid from public.customers where lower(email) = a.email and not coalesce(is_agency, false) order by created_at limit 1;
    if cid is null then
      insert into public.customers (name, email, phone, tier, price_group, country, notes, is_fighter, fighter_free)
      values (a.name, a.email, a.phone, 'train', 'standard', a.country, 'Fight team, applied on the website', true, false) returning id into cid;
    else
      update public.customers set is_fighter = true, phone = coalesce(phone, a.phone), country = coalesce(country, a.country) where id = cid;
    end if;
  end if;
  update public.fighter_applications set status = case when p_ok then 'accepted' else 'declined' end, note = nullif(btrim(coalesce(p_note,'')),''), customer_id = cid where id = p_id;
  return cid;
end $$;

revoke all on function public.fighter_apply(jsonb) from public;
grant execute on function public.fighter_apply(jsonb) to anon, authenticated;
revoke all on function public.fighter_apps(), public.fighter_app_decide(uuid, boolean, text) from public, anon;
grant execute on function public.fighter_apps(), public.fighter_app_decide(uuid, boolean, text) to authenticated;
