delete from mf.template where name like 'fighter_apply:%';
insert into mf.template (ord, phase, kind, name, sql) values (300901, 3, 'patch', 'fighter_apply:300901', $TPL$create table if not exists __P__.fighter_applications (
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
  customer_id uuid references __P__.customers(id) on delete set null,
  created_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (300902, 3, 'patch', 'fighter_apply:300902', $TPL$alter table __P__.fighter_applications enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401401, 4, 'patch', 'fighter_apply:401401', $TPL$create or replace function __P__.fighter_apply(p jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare v_name text := btrim(coalesce(p->>'name','')); v_email text := lower(btrim(coalesce(p->>'email',''))); v_id uuid; t text;
  num int := nullif(regexp_replace(coalesce(p->>'followers',''), '[^0-9]', '', 'g'), '')::numeric::int;
begin
  if not __Q__.feature('fighter_apply', true) then raise exception 'Applications are closed right now. Message us on WhatsApp.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 80 then raise exception 'Type your full name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 120 then raise exception 'Type a real email address.'; end if;
  if (select count(*) from __P__.fighter_applications where email = v_email and created_at > now() - interval '1 day') >= 2
     or (select count(*) from __P__.fighter_applications where created_at > now() - interval '1 hour') >= 20 then
    raise exception 'We already have your application. We will be in touch.'; end if;
  t := nullif(btrim(coalesce(p->>'arrive','')), '');
  insert into __P__.fighter_applications (name, email, phone, country, age, weight, record, experience, links, followers, arrive, months, goals)
  values (v_name, v_email, left(nullif(btrim(coalesce(p->>'phone','')),''),40), left(nullif(btrim(coalesce(p->>'country','')),''),60),
    case when coalesce(p->>'age','') ~ '^[0-9]{1,2}$' then (p->>'age')::int end, left(nullif(btrim(coalesce(p->>'weight','')),''),40),
    left(nullif(btrim(coalesce(p->>'record','')),''),200), left(nullif(btrim(coalesce(p->>'experience','')),''),1500), left(nullif(btrim(coalesce(p->>'links','')),''),600),
    case when num between 0 and 1000000000 then num end,
    case when t ~ '^\d{4}-\d{2}-\d{2}$' then t::date end,
    case when coalesce(p->>'months','') ~ '^[0-9]{1,2}$' then (p->>'months')::int end,
    left(nullif(btrim(coalesce(p->>'goals','')),''),1500))
  returning id into v_id;
  return jsonb_build_object('ok', true);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401402, 4, 'patch', 'fighter_apply:401402', $TPL$create or replace function __P__.fighter_apps() returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see fighter applications.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(a) order by (a.status = 'new') desc, a.created_at desc) from (select * from __P__.fighter_applications order by created_at desc limit 100) a), '[]'::jsonb);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401403, 4, 'patch', 'fighter_apply:401403', $TPL$create or replace function __P__.fighter_app_decide(p_id uuid, p_ok boolean, p_note text default null) returns uuid
language plpgsql security definer set search_path to '' as $$
declare a __P__.fighter_applications%rowtype; cid uuid;
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  select * into a from __P__.fighter_applications where id = p_id for update;
  if a.id is null then raise exception 'That application is not there any more.'; end if;
  if p_ok then
    select id into cid from __P__.customers where lower(email) = a.email and not coalesce(is_agency, false) order by created_at limit 1;
    if cid is null then
      insert into __P__.customers (name, email, phone, tier, price_group, country, notes, is_fighter, fighter_free)
      values (a.name, a.email, a.phone, 'train', 'standard', a.country, 'Fight team, applied on the website', true, false) returning id into cid;
    else
      update __P__.customers set is_fighter = true, phone = coalesce(phone, a.phone), country = coalesce(country, a.country) where id = cid;
    end if;
  end if;
  update __P__.fighter_applications set status = case when p_ok then 'accepted' else 'declined' end, note = nullif(btrim(coalesce(p_note,'')),''), customer_id = cid where id = p_id;
  return cid;
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1195201, 11, 'patch', 'fighter_apply:1195201', $TPL$revoke all on function __P__.fighter_apply(jsonb) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1195202, 11, 'patch', 'fighter_apply:1195202', $TPL$grant execute on function __P__.fighter_apply(jsonb) to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1195203, 11, 'patch', 'fighter_apply:1195203', $TPL$revoke all on function __P__.fighter_apps(), __P__.fighter_app_decide(uuid, boolean, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1195204, 11, 'patch', 'fighter_apply:1195204', $TPL$grant execute on function __P__.fighter_apps(), __P__.fighter_app_decide(uuid, boolean, text) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'fighter_apply:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
