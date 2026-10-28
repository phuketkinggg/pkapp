-- Course offer on room bookings (feature: course_offer): the online course on offer can be added when someone
-- books a room on the website, as an extra on the stay. It is unlocked in their app as soon as it is paid.

alter table public.purchases add column if not exists course_id uuid references public.courses(id) on delete set null;

-- the course as a stay extra: checked and priced here, never by the page
create or replace function public.web_course_item(p_course text, p_email text, p_training boolean default false) returns jsonb
language plpgsql stable security definer set search_path to '' as $f$
declare c public.courses; em text := lower(btrim(coalesce(p_email, '')));
begin
  if nullif(p_course, '') is null then return null; end if;
  if not private.feature('course_offer', true) then raise exception 'The course offer is not available.'; end if;
  begin select * into c from public.courses where id = p_course::uuid and offer_on; exception when others then c := null; end;
  if c.id is null then raise exception 'That course offer has ended. Untick it and try again.'; end if;
  if c.offer_with = 'training' and not coalesce(p_training, false) then raise exception 'The course offer goes with training. Untick it, or add training to your stay.'; end if;
  if em <> '' and exists (select 1 from public.course_access a join public.customers cu on cu.id = a.customer_id where a.course_id = c.id and lower(cu.email) = em) then
    raise exception 'You already have this course. Untick it and try again.'; end if;
  if em <> '' and c.offer_new_only and exists (select 1 from public.purchases pu join public.customers cu on cu.id = pu.customer_id
      where lower(cu.email) = em and pu.stay_id is null and pu.for_stay is null and not coalesce(pu.cancelled, false)) then
    raise exception 'The course offer is for new members. Untick it, or buy the course on its own.'; end if;
  if coalesce(c.offer_price_thb, c.price_thb, 0) < 20 then raise exception 'That course offer has no price yet.'; end if;
  return jsonb_build_object('course_id', c.id, 'price', coalesce(c.offer_price_thb, c.price_thb), 'name', 'Online course: ' || c.title, 'covers', '[]'::jsonb);
end $f$;
revoke all on function public.web_course_item(text, text, boolean) from public, anon, authenticated;
grant execute on function public.web_course_item(text, text, boolean) to service_role;

-- stay extras keep the course they are for
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.web_add_items(uuid,jsonb)') is null then raise notice 'no web_add_items, skipped'; return; end if;
  d := pg_get_functiondef('public.web_add_items(uuid,jsonb)'::regprocedure);
  if position('course_id' in d) > 0 then raise notice 'web_add_items already patched'; return; end if;
  if position('for_stay, ordered_in_app)' in d) = 0 or position('s.id, true);' in d) = 0 then raise notice 'web_add_items: older version, skipped'; return; end if;
  n := replace(replace(d, 'for_stay, ordered_in_app)', 'for_stay, ordered_in_app, course_id)'),
    's.id, true);', 's.id, true, case when coalesce(it->>''course_id'','''') ~ ''^[0-9a-f-]{36}$'' then (it->>''course_id'')::uuid end);');
  execute n;
  if position('course_id' in pg_get_functiondef('public.web_add_items(uuid,jsonb)'::regprocedure)) = 0 then raise exception 'web_add_items patch did not apply'; end if;
end $p$;

-- paid in full: the course opens in their app
create or replace function private.purchase_course_grant() returns trigger language plpgsql security definer set search_path to '' as $f$
begin
  if new.course_id is not null and not coalesce(new.cancelled, false) and new.refunded_at is null
     and (new.paid or coalesce(new.paid_thb, 0) >= coalesce(new.price_thb, 0)) and coalesce(new.price_thb, 0) > 0 then
    insert into public.course_access (customer_id, course_id, source) values (new.customer_id, new.course_id, 'bought') on conflict do nothing;
  end if;
  return null;
end $f$;
drop trigger if exists purchases_course_grant on public.purchases;
create trigger purchases_course_grant after insert or update of paid, paid_thb on public.purchases for each row execute function private.purchase_course_grant();

notify pgrst, 'reload schema';
