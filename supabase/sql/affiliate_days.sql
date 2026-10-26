-- How long an affiliate link counts after the visit: one setting for the business (app_settings affiliate_days, 60 unless changed)
-- and, if wanted, a different number for one affiliate (affiliates.days). The website sends when the link was clicked.

alter table public.affiliates add column if not exists days integer check (days is null or days between 1 and 730);
insert into public.app_settings (key, value) values ('affiliate_days', '60') on conflict (key) do nothing;

create or replace function private.aff_days(a public.affiliates) returns integer language sql stable set search_path to '' as $$
  select coalesce(a.days, (select case when value ~ '^[0-9]{1,3}$' then value::int end from public.app_settings where key = 'affiliate_days'), 60)
$$;

-- the link only counts while it is fresh (p_at: when the visitor clicked it; null = now, for a booking tagged by hand)
drop function if exists public.affiliate_tag_stay(uuid, text);
create or replace function public.affiliate_tag_stay(p_stay uuid, p_code text, p_at timestamptz default null) returns boolean language plpgsql security definer set search_path to '' as $$
declare a public.affiliates;
begin
  select * into a from public.affiliates where code = lower(trim(coalesce(p_code,''))) and active;
  if a.id is null or private.aff_pct(a, 'stay', null) is null then return false; end if;
  if p_at is not null and p_at < now() - make_interval(days => private.aff_days(a)) then return false; end if;
  update public.stays set affiliate_id = a.id where id = p_stay and affiliate_id is null;
  return found;
end $$;
revoke all on function public.affiliate_tag_stay(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.affiliate_tag_stay(uuid, text, timestamptz) to service_role;

drop function if exists public.affiliate_tag_order(uuid, text);
create or replace function public.affiliate_tag_order(p_order uuid, p_code text, p_at timestamptz default null) returns boolean language plpgsql security definer set search_path to '' as $$
declare a public.affiliates; o public.web_pkg_orders;
begin
  select * into a from public.affiliates where code = lower(trim(coalesce(p_code,''))) and active;
  if a.id is null then return false; end if;
  if p_at is not null and p_at < now() - make_interval(days => private.aff_days(a)) then return false; end if;
  select * into o from public.web_pkg_orders where id = p_order;
  if o.id is null or o.affiliate_id is not null then return false; end if;
  if o.package_id is null and o.course_id is not null then
    if private.aff_pct(a, 'course', o.course_id) is null then return false; end if;
    update public.web_pkg_orders set affiliate_id = a.id, affiliate_pct = private.aff_pct(a, 'course', o.course_id) where id = p_order;
    return true;
  end if;
  if o.package_id is not null and private.aff_pct(a, 'package', o.package_id) is null then return false; end if;
  update public.web_pkg_orders set affiliate_id = a.id where id = p_order;
  if o.purchase_id is not null then update public.purchases set affiliate_id = a.id where id = o.purchase_id and affiliate_id is null; end if;
  return true;
end $$;
revoke all on function public.affiliate_tag_order(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.affiliate_tag_order(uuid, text, timestamptz) to service_role;

-- manager: the number of days for everyone, and for one affiliate (null = the same as everyone)
create or replace function public.affiliate_days_set(p_days integer, p_id uuid default null) returns void language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change affiliates.'; end if;
  if p_days is not null and (p_days < 1 or p_days > 730) then raise exception 'Choose between 1 and 730 days.'; end if;
  if p_id is null then
    if p_days is null then raise exception 'Choose the number of days.'; end if;
    update public.app_settings set value = p_days::text where key = 'affiliate_days';
    if not found then insert into public.app_settings (key, value) values ('affiliate_days', p_days::text); end if;
  else
    update public.affiliates set days = p_days where id = p_id;
    if not found then raise exception 'Not found.'; end if;
  end if;
end $$;
revoke all on function public.affiliate_days_set(integer, uuid) from public, anon;
grant execute on function public.affiliate_days_set(integer, uuid) to authenticated;

-- the affiliate's card shows how long their link counts
do $$ declare s text;
begin
  s := pg_get_functiondef('private.aff_row(public.affiliates,boolean)'::regprocedure);
  if s like '%aff_days%' then return; end if;
  s := replace(s, $a$'note', a.note, 'rules', a.rules,$a$, $a$'note', a.note, 'rules', a.rules, 'days', private.aff_days(a), 'own_days', a.days,$a$);
  if s not like '%aff_days%' then raise notice 'aff_row is a different version here: skipped.'; return; end if;
  execute s;
end $$;
