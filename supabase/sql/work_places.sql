-- Places (every room plus areas like the kitchen, Pangea garden, gym, spa, shop) so receipts and work done can be tied to one place.
-- Receipts get "where" and "what is it for". Work log: staff report work done at a place on a date; each place shows its work and its receipts together.

create table if not exists public.places (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  room_id uuid unique references public.rooms(id) on delete set null,
  business text not null default 'Pangea Resort' check (business in ('Phuket King Gym','Pangea Resort')),
  sort int not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.places enable row level security;

insert into public.places (name, room_id, business, sort)
select r.name, r.id, 'Pangea Resort', coalesce(r.sort, 0) from public.rooms r
where coalesce(r.active, true) and not exists (select 1 from public.places p where p.room_id = r.id);

insert into public.places (name, business, sort)
select v.name, v.business, v.sort from (values
  ('Kitchen','Pangea Resort',200),('Pangea Cafe','Pangea Resort',201),('Pangea Garden','Pangea Resort',202),('Resort grounds and paths','Pangea Resort',203),
  ('Reception','Pangea Resort',204),('Laundry','Pangea Resort',205),('Staff rooms','Pangea Resort',206),('Water, pumps and electrics','Pangea Resort',207),
  ('Gym','Phuket King Gym',300),('Boxing ring','Phuket King Gym',301),('Gym bathrooms','Phuket King Gym',302),('Spa','Phuket King Gym',303),
  ('Sauna and ice bath','Phuket King Gym',304),('Gym shop','Phuket King Gym',305),('Other','Pangea Resort',900)
) v(name, business, sort)
where not exists (select 1 from public.places p where p.room_id is null);

alter table public.expense_receipts add column if not exists place_id uuid references public.places(id) on delete set null;
alter table public.expense_receipts add column if not exists purpose text;

create table if not exists public.work_logs (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places(id),
  day date not null,
  title text not null,
  details text not null default '',
  done_by text not null default '',
  cost numeric check (cost is null or cost >= 0),
  photo_paths text[] not null default '{}',
  created_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  removed boolean not null default false
);
create index if not exists work_logs_place on public.work_logs (place_id, day desc);
alter table public.work_logs enable row level security;

create or replace function private.money_boss() returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce(private.staff_role(),'') = 'manager' and private.can('money') $$;

create or replace function public.places_list() returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'room',p.room_id is not null,'business',p.business,'active',p.active,'sort',p.sort) order by (p.room_id is null), p.sort, p.name)
    from public.places p), '[]'::jsonb);
end $$;

create or replace function public.place_save(p jsonb) returns uuid
language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid; n text := btrim(coalesce(p->>'name','')); b text := coalesce(nullif(p->>'business',''),'Pangea Resort');
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change places.'; end if;
  if n = '' then raise exception 'Give the place a name.'; end if;
  if b not in ('Phuket King Gym','Pangea Resort') then raise exception 'Choose the business.'; end if;
  if v is null then
    insert into public.places (name, business, sort) values (left(n,80), b, coalesce(nullif(p->>'sort','')::int, 500)) returning id into v;
  else
    update public.places set name = left(n,80), business = b, active = coalesce((p->>'active')::boolean, active), sort = coalesce(nullif(p->>'sort','')::int, sort) where id = v;
  end if;
  return v;
end $$;

-- receipts: where and what for
create or replace function public.receipt_add(p jsonb)
 returns uuid language plpgsql security definer set search_path to '' as $function$
declare v uuid; dept text := btrim(coalesce(p->>'department','')); amt numeric := nullif(p->>'amount','')::numeric; pl uuid := nullif(p->>'place_id','')::uuid;
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  if dept = '' then raise exception 'Choose the department.'; end if;
  if coalesce(p->>'photo_path','') = '' then raise exception 'Take a photo of the receipt.'; end if;
  if split_part(p->>'photo_path','/',1) <> auth.uid()::text then raise exception 'Photo upload did not match. Try again.'; end if;
  if amt is not null and (amt < 0 or amt > 10000000) then raise exception 'Check the amount.'; end if;
  if pl is not null and not exists (select 1 from public.places where id = pl) then pl := null; end if;
  insert into public.expense_receipts(staff_id, day, department, business, amount_thb, method, supplier, note, photo_path, place_id, purpose)
    values (private.my_staff_id(), coalesce(nullif(p->>'day','')::date, private.bkk_today()), left(dept,60), private.receipt_business(dept), amt,
      coalesce(nullif(p->>'method',''),'transfer'), nullif(left(btrim(coalesce(p->>'supplier','')),120),''), nullif(left(btrim(coalesce(p->>'note','')),300),''), p->>'photo_path',
      pl, nullif(left(btrim(coalesce(p->>'purpose','')),300),''))
    returning id into v;
  return v;
end $function$;

do $$ declare d text := pg_get_functiondef('public.receipt_save(jsonb)'::regprocedure); begin
  if position('purpose' in d) = 0 then
    d := replace(d, 'note = nullif(btrim(coalesce(p->>''note'','''')),''''),',
      'note = nullif(btrim(coalesce(p->>''note'','''')),''''),
    place_id = case when p ? ''place_id'' then nullif(p->>''place_id'','''')::uuid else place_id end,
    purpose = case when p ? ''purpose'' then nullif(left(btrim(coalesce(p->>''purpose'','''')),300),'''') else purpose end,');
    if position('purpose' in d) = 0 then raise exception 'receipt_save patch did not apply'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.receipts_list(date,date)'::regprocedure);
  if position('purpose' in d) = 0 then
    d := replace(d, '''at'',r.created_at)', '''at'',r.created_at,''place_id'',r.place_id,''place'',(select pl.name from public.places pl where pl.id = r.place_id),''purpose'',r.purpose)');
    if position('purpose' in d) = 0 then raise exception 'receipts_list patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- work done
create or replace function public.work_save(p jsonb) returns uuid
language plpgsql security definer set search_path to '' as $$
declare v uuid := nullif(p->>'id','')::uuid; pl uuid := nullif(p->>'place_id','')::uuid; t text := btrim(coalesce(p->>'title',''));
  d date := coalesce(nullif(p->>'day','')::date, private.bkk_today()); c numeric := nullif(p->>'cost','')::numeric; ph text[]; x text; owner uuid;
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  if pl is null or not exists (select 1 from public.places where id = pl) then raise exception 'Choose where the work was done.'; end if;
  if t = '' then raise exception 'Write what was done.'; end if;
  if d > private.bkk_today() then raise exception 'The date cannot be in the future.'; end if;
  if c is not null and (c < 0 or c > 10000000) then raise exception 'Check the cost.'; end if;
  select coalesce(array_agg(y), '{}') into ph from jsonb_array_elements_text(case when jsonb_typeof(p->'photos') = 'array' then p->'photos' else '[]'::jsonb end) y;
  if cardinality(ph) > 6 then raise exception 'Up to 6 photos.'; end if;
  if v is null then
    foreach x in array ph loop if split_part(x,'/',1) <> auth.uid()::text then raise exception 'Photo upload did not match. Try again.'; end if; end loop;
    insert into public.work_logs (place_id, day, title, details, done_by, cost, photo_paths, created_by)
    values (pl, d, left(t,160), left(coalesce(p->>'details',''),2000), left(btrim(coalesce(p->>'done_by','')),120), c, ph, private.my_staff_id())
    returning id into v;
  else
    select created_by into owner from public.work_logs where id = v and not removed;
    if not found then raise exception 'Not found.'; end if;
    if owner is distinct from private.my_staff_id() and coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the person who added it or a manager can change it.'; end if;
    update public.work_logs set place_id = pl, day = d, title = left(t,160), details = left(coalesce(p->>'details',''),2000), done_by = left(btrim(coalesce(p->>'done_by','')),120),
      cost = c, photo_paths = case when p ? 'photos' then ph else photo_paths end, updated_at = now() where id = v;
  end if;
  return v;
end $$;

create or replace function public.work_remove(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare owner uuid;
begin
  select created_by into owner from public.work_logs where id = p_id and not removed;
  if not found then raise exception 'Not found.'; end if;
  if owner is distinct from private.my_staff_id() and coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only the person who added it or a manager can remove it.'; end if;
  update public.work_logs set removed = true, updated_at = now() where id = p_id;
end $$;

-- the work log page: every place with its work and receipts in the period (money only for managers with money access)
create or replace function public.work_home(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare boss boolean := private.money_boss(); me_s uuid := private.my_staff_id();
begin
  if not private.any_staff() then raise exception 'Not allowed.'; end if;
  return jsonb_build_object('boss', boss, 'me', me_s,
    'places', public.places_list(),
    'work', coalesce((select jsonb_agg(jsonb_build_object('id',w.id,'place_id',w.place_id,'day',w.day,'title',w.title,'details',w.details,'done_by',w.done_by,
        'cost',case when boss or w.created_by = me_s then w.cost end,'photos',w.photo_paths,'by',s.name,'mine',w.created_by = me_s,'at',w.created_at) order by w.day desc, w.created_at desc)
      from public.work_logs w left join public.staff s on s.id = w.created_by
      where not w.removed and w.day between p_from and p_to), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'place_id',r.place_id,'day',r.day,'supplier',r.supplier,'purpose',r.purpose,'amount',r.amount_thb,
        'category',r.category,'photo_path',r.photo_path,'by',s.name) order by r.day desc)
      from public.expense_receipts r left join public.staff s on s.id = r.staff_id
      where r.place_id is not null and r.status <> 'removed' and r.day between p_from and p_to and (boss or r.staff_id = me_s)), '[]'::jsonb));
end $$;

revoke all on function public.places_list(), public.place_save(jsonb), public.work_save(jsonb), public.work_remove(uuid), public.work_home(date,date) from public, anon;
grant execute on function public.places_list(), public.place_save(jsonb), public.work_save(jsonb), public.work_remove(uuid), public.work_home(date,date) to authenticated;

-- work photos (receipts bucket, folder <user>/work/) can be seen by all staff
do $$ begin
  create policy work_photos_view on storage.objects for select to authenticated
    using (bucket_id = 'receipts' and (select private.any_staff()) and (storage.foldername(name))[2] = 'work');
exception when duplicate_object then null; end $$;
