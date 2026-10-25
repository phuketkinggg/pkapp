-- Course offer: one online course can be offered as a tick box when someone buys a package
-- (on the website and at the desk). Its own price for the offer, the words shown, which packages it goes with,
-- and whether it is for new members only (their first package). Feature switch: course_offer.

alter table public.courses add column if not exists offer_on boolean not null default false;
alter table public.courses add column if not exists offer_price_thb integer;
alter table public.courses add column if not exists offer_text text;
alter table public.courses add column if not exists offer_new_only boolean not null default true;
alter table public.courses add column if not exists offer_with text not null default 'training';
do $$ begin
  alter table public.courses add constraint courses_offer_with_chk check (offer_with in ('training','all'));
exception when duplicate_object then null; end $$;

-- the course on offer (anyone: the website shows it in the buy box)
create or replace function public.course_offer() returns jsonb language sql stable security definer set search_path to '' as $$
  select case when private.feature('course_offer', true) then (
    select jsonb_build_object('id', c.id, 'title', c.title, 'summary', c.summary, 'text', c.offer_text, 'cover', c.cover_url,
      'price', coalesce(c.offer_price_thb, c.price_thb), 'full_price', c.price_thb, 'new_only', c.offer_new_only, 'with', c.offer_with)
    from public.courses c where c.offer_on and coalesce(c.offer_price_thb, c.price_thb, 0) >= 20 order by c.sort, c.created_at limit 1) end
$$;
grant execute on function public.course_offer() to anon, authenticated;

-- manager: read and set the offer on a course (one course on offer at a time)
create or replace function public.course_offer_get(p_course uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do that.'; end if;
  return (select jsonb_build_object('on', offer_on, 'price', offer_price_thb, 'text', offer_text, 'new_only', offer_new_only, 'with', offer_with, 'full_price', price_thb)
    from public.courses where id = p_course);
end $$;
create or replace function public.course_offer_set(p_course uuid, p jsonb) returns void language plpgsql security definer set search_path to '' as $$
declare pr int;
begin
  if coalesce(private.staff_role(), '') <> 'manager' then raise exception 'Only a manager can do that.'; end if;
  pr := nullif(p->>'price', '')::numeric::int;
  if pr is not null and (pr < 20 or pr > 1000000) then raise exception 'The offer price must be at least 20 THB.'; end if;
  if coalesce((p->>'on')::boolean, false) and coalesce(pr, (select price_thb from public.courses where id = p_course), 0) < 20 then
    raise exception 'Set a price for the offer, or a price on the course.'; end if;
  if coalesce((p->>'on')::boolean, false) then update public.courses set offer_on = false where offer_on and id <> p_course; end if;
  update public.courses set offer_on = coalesce((p->>'on')::boolean, false), offer_price_thb = pr,
    offer_text = nullif(left(btrim(coalesce(p->>'text', '')), 600), ''), offer_new_only = coalesce((p->>'new_only')::boolean, true),
    offer_with = case when p->>'with' = 'all' then 'all' else 'training' end, updated_at = now()
  where id = p_course;
  if not found then raise exception 'Course not found.'; end if;
end $$;
revoke all on function public.course_offer_get(uuid) from public, anon;
revoke all on function public.course_offer_set(uuid, jsonb) from public, anon;
grant execute on function public.course_offer_get(uuid) to authenticated;
grant execute on function public.course_offer_set(uuid, jsonb) to authenticated;

-- the course added to a website order: checked and priced here, never by the page
create or replace function private.course_addon(p_id text, p_email text, k public.packages) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare c public.courses;
begin
  if nullif(p_id, '') is null then return null; end if;
  if not private.feature('course_offer', true) then raise exception 'The course offer is not available.'; end if;
  begin select * into c from public.courses where id = p_id::uuid and offer_on; exception when others then c := null; end;
  if c.id is null then raise exception 'That course offer has ended. Untick it and try again.'; end if;
  if c.offer_with = 'training' and not ('Muay Thai' = any (coalesce(k.covers, '{}'))) then raise exception 'The course offer goes with Muay Thai training packages. Untick it for this package.'; end if;
  if exists (select 1 from public.course_access a join public.customers cu on cu.id = a.customer_id where a.course_id = c.id and lower(cu.email) = p_email) then
    raise exception 'You already have this course. Untick it and try again.'; end if;
  if c.offer_new_only and exists (select 1 from public.purchases pu join public.customers cu on cu.id = pu.customer_id
      where lower(cu.email) = p_email and pu.stay_id is null and not coalesce(pu.cancelled, false)) then
    raise exception 'The course offer is for new members, on their first package. Untick it, or buy the course on its own.'; end if;
  if coalesce(c.offer_price_thb, c.price_thb, 0) < 20 then raise exception 'That course offer has no price yet.'; end if;
  return jsonb_build_object('course_id', c.id, 'price', coalesce(c.offer_price_thb, c.price_thb), 'label', 'Course: ' || c.title, 'name', c.title);
end $$;

-- website order: the course goes in the order as an extra, and in the total
do $$ declare s text; o text;
begin
  s := pg_get_functiondef('public.web_pkg_order(jsonb)'::regprocedure); o := s;
  if s like '%course_addon%' then return; end if;
  s := replace(s, $a$declare k public.packages;$a$, $a$declare co jsonb; k public.packages;$a$);
  s := replace(s, $a$  insert into public.web_pkg_orders (package_id, package_name, price_thb, pkg_price_thb, extras, name, email, phone, start_on, note, private_req)
    values (k.id, k.name || coalesce(' + ' || (ex->>'label'), '') || case when coalesce((ex->>'coach_extra')::int,0) > 0 then ' + coach top up' else '' end, tot, k.price_thb, case when ex is not null and ex->>'package_id' is not null then jsonb_build_array(ex - 'coach_extra') end,$a$,
  $a$  -- an online course added with the package (Courses, Offer it when someone buys a package)
  co := private.course_addon(p->>'course_addon', em, k);
  tot := tot + coalesce((co->>'price')::int, 0);
  insert into public.web_pkg_orders (package_id, package_name, price_thb, pkg_price_thb, extras, name, email, phone, start_on, note, private_req)
    values (k.id, k.name || coalesce(' + ' || (ex->>'label'), '') || case when coalesce((ex->>'coach_extra')::int,0) > 0 then ' + coach top up' else '' end || coalesce(' + ' || (co->>'label'), ''), tot, k.price_thb,
      nullif(coalesce(case when ex is not null and ex->>'package_id' is not null then jsonb_build_array(ex - 'coach_extra') end, '[]'::jsonb) || coalesce(jsonb_build_array(co), '[]'::jsonb), '[]'::jsonb),$a$);
  s := replace(s, $a$'what', k.name || coalesce(' + ' || (ex->>'label'), ''), 'email', em, 'private', pr)$a$,
    $a$'what', k.name || coalesce(' + ' || (ex->>'label'), '') || coalesce(' + ' || (co->>'label'), ''), 'email', em, 'private', pr)$a$);
  if s not like '%private.course_addon(%' or s not like '%(co->>''label'')%(co->>''label'')%' then
    raise notice 'web_pkg_order is a different version here: the course offer is not added to website orders on this database.'; return; end if;
  execute s;
end $$;

-- paid: the course is unlocked, with its own payment line
do $$ declare s text;
begin
  s := pg_get_functiondef('private.web_pkg_paid(uuid,text,integer)'::regprocedure);
  if s like '%course offer%' then return; end if;
  s := replace(s, $a$  for e in select * from jsonb_array_elements(coalesce(o.extras, '[]'::jsonb)) loop
    select * into k2 from public.packages where id = (e->>'package_id')::uuid;$a$,
  $a$  for e in select * from jsonb_array_elements(coalesce(o.extras, '[]'::jsonb)) loop
    if e ? 'course_id' then  -- the course offer: unlocked in their app, paid as its own line
      insert into public.course_access (customer_id, course_id, source) values (cid, (e->>'course_id')::uuid, 'bought') on conflict do nothing;
      insert into public.payments (customer_id, amount_thb, method, note, stripe_session)
        values (cid, (e->>'price')::int, meth, coalesce(e->>'label', 'Course') || ', website, with ' || coalesce(k.name, 'a package'), p_session || ':course');
      continue;
    end if;
    select * into k2 from public.packages where id = (e->>'package_id')::uuid;$a$);
  if s not like '%course offer%' then raise notice 'web_pkg_paid is a different version here: skipped.'; return; end if;
  execute s;
end $$;
