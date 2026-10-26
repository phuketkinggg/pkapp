-- Coaching is chosen per customer: not everyone gets it. Each customer can have none, or any of
-- steps (habits and weekly steps), workouts, food (food diary and meal advice) and weight.
-- customers.coaching null = the business default (app_settings coaching_default, a comma list; empty = no coaching).
-- Owners can also open any customer's app as they see it, now including Coaching and Learn.

alter table public.customers add column if not exists coaching text[];
insert into public.app_settings (key, value) values ('coaching_default', '') on conflict (key) do nothing;

-- people who already have coaching keep all of it
update public.customers c set coaching = array['steps','workouts','food','weight']
where c.coaching is null and (
  exists (select 1 from public.coach_clients x where x.customer_id = c.id)
  or exists (select 1 from public.habits x where x.customer_id = c.id)
  or exists (select 1 from public.programs x where x.customer_id = c.id and not x.removed)
  or exists (select 1 from public.food_logs x where x.customer_id = c.id)
  or exists (select 1 from public.weights x where x.customer_id = c.id)
  or exists (select 1 from public.group_members m where m.customer_id = c.id and not m.removed
             and not exists (select 1 from public.courses k where m.group_id = any(k.group_ids))));

create or replace function private.coaching_parts(p_customer uuid) returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(p order by array_position(array['steps','workouts','food','weight'], p)), '[]'::jsonb)
  from unnest(coalesce((select c.coaching from public.customers c where c.id = p_customer),
                       (select string_to_array(nullif(trim(value),''), ',') from public.app_settings where key = 'coaching_default'),
                       array[]::text[])) p
  where p in ('steps','workouts','food','weight')
$$;

-- staff: what this customer gets (null parts = back to the business default)
create or replace function public.coaching_parts_set(p_customer uuid, p_parts text[]) returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin','coach') then raise exception 'Only a manager or coach can change coaching.'; end if;
  update public.customers set coaching = case when p_parts is null then null
    else array(select distinct p from unnest(p_parts) p where p in ('steps','workouts','food','weight')) end where id = p_customer;
  if not found then raise exception 'Not found.'; end if;
  return private.coaching_parts(p_customer);
end $$;
revoke all on function public.coaching_parts_set(uuid, text[]) from public, anon;
grant execute on function public.coaching_parts_set(uuid, text[]) to authenticated;

create or replace function public.coaching_default_set(p_parts text[]) returns void language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  update public.app_settings set value = array_to_string(array(select distinct p from unnest(coalesce(p_parts, array[]::text[])) p where p in ('steps','workouts','food','weight')), ',')
  where key = 'coaching_default';
  if not found then insert into public.app_settings (key, value) values ('coaching_default', array_to_string(coalesce(p_parts, array[]::text[]), ',')); end if;
end $$;
revoke all on function public.coaching_default_set(text[]) from public, anon;
grant execute on function public.coaching_default_set(text[]) to authenticated;

-- giving someone a coach turns coaching on for them, if they had none
create or replace function private.coach_client_on() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if jsonb_array_length(private.coaching_parts(new.customer_id)) = 0 then
    update public.customers set coaching = array['steps','workouts','food','weight'] where id = new.customer_id;
  end if;
  return null;
end $$;
drop trigger if exists coach_clients_on on public.coach_clients;
create trigger coach_clients_on after insert on public.coach_clients for each row execute function private.coach_client_on();

-- the app knows which parts to show
do $$ declare s text;
begin
  s := pg_get_functiondef('private.coaching_data(uuid,boolean)'::regprocedure);
  if s like '%coaching_parts%' then return; end if;
  s := replace(s, $a$'today', private.bkk_today(),$a$, $a$'today', private.bkk_today(), 'parts', private.coaching_parts(p_customer),$a$);
  if s not like '%coaching_parts%' then raise notice 'coaching_data is a different version here: skipped.'; return; end if;
  execute s;
end $$;
do $$ declare s text; f text;
begin
  foreach f in array array['public.customer_home()','public.customer_home_as(uuid)'] loop
    s := pg_get_functiondef(f::regprocedure);
    if s like '%coaching_parts%' then continue; end if;
    s := replace(s, $a$'owes', private.customer_owes(c.id),$a$, $a$'owes', private.customer_owes(c.id), 'coaching', private.coaching_parts(c.id),$a$);
    if s not like '%coaching_parts%' then raise notice '% is a different version here: skipped.', f; continue; end if;
    execute s;
  end loop;
end $$;

-- the owner looks at a customer's coaching as they see it
create or replace function public.coaching_as(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Coaching is private. Open it in the back office, in the Coaching tab.'; end if;
  return private.coaching_data(p_customer, false);
end $$;
revoke all on function public.coaching_as(uuid) from public, anon;
grant execute on function public.coaching_as(uuid) to authenticated;

-- courses as a customer sees them: staff normally see every lesson, so while looking as a customer that is switched off (pk.as)
do $$ declare s text;
begin
  s := pg_get_functiondef('private.course_open(uuid,uuid)'::regprocedure);
  if s like '%pk.as%' then return; end if;
  s := replace(s, $a$or coalesce(private.staff_role() is not null, false)$a$, $a$or (coalesce(private.staff_role() is not null, false) and coalesce(current_setting('pk.as', true), '') <> '1')$a$);
  if s not like '%pk.as%' then raise notice 'course_open is a different version here: skipped.'; return; end if;
  execute s;
end $$;
do $$ declare s text;
begin
  s := pg_get_functiondef('private.lesson_opens(public.course_lessons,uuid)'::regprocedure);
  if s like '%pk.as%' then return; end if;
  s := replace(s, $a$when l.free or coalesce(private.staff_role() is not null, false) then$a$, $a$when l.free or (coalesce(private.staff_role() is not null, false) and coalesce(current_setting('pk.as', true), '') <> '1') then$a$);
  if s not like '%pk.as%' then raise notice 'lesson_opens is a different version here: skipped.'; return; end if;
  execute s;
end $$;

create or replace function public.course_list_as(p_customer uuid) returns jsonb language plpgsql security definer set search_path to '' as $$
declare cid uuid := p_customer;
begin
  if coalesce(private.staff_role(),'') not in ('manager','front_desk','resort') then raise exception 'Not allowed.'; end if;
  perform set_config('pk.as', '1', true);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'title', c.title, 'summary', c.summary, 'cover', c.cover_url, 'price', c.price_thb,
      'members_free', c.members_free, 'status', c.status, 'open', private.course_open(c.id, cid),
      'count', (select count(*) from public.course_lessons l where l.course_id = c.id and not l.removed),
      'done', (select count(*) from public.course_progress pr join public.course_lessons l on l.id = pr.lesson_id where l.course_id = c.id and not l.removed and pr.customer_id = cid and pr.done)) order by c.sort, c.created_at), '[]'::jsonb)
    from public.courses c where c.status = 'published');
end $$;
revoke all on function public.course_list_as(uuid) from public, anon;
grant execute on function public.course_list_as(uuid) to authenticated;

create or replace function public.course_view_as(p_course uuid, p_customer uuid) returns jsonb language plpgsql security definer set search_path to '' as $$
declare cid uuid := p_customer; c public.courses; op boolean;
begin
  if coalesce(private.staff_role(),'') not in ('manager','front_desk','resort') then raise exception 'Not allowed.'; end if;
  perform set_config('pk.as', '1', true);
  select * into c from public.courses where id = p_course and status = 'published';
  if c.id is null then raise exception 'That course was not found.'; end if;
  op := private.course_open(c.id, cid);
  return jsonb_build_object('id', c.id, 'slug', c.slug, 'title', c.title, 'summary', c.summary, 'about', c.about, 'cover', c.cover_url, 'price', c.price_thb,
    'members_free', c.members_free, 'status', c.status, 'sort', c.sort, 'open', op,
    'lessons', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'title', l.title, 'minutes', l.minutes, 'free', l.free, 'sort', l.sort,
        'open_day', l.open_day, 'open_on', l.open_on,
        'opens', case when op and not l.free and not private.lesson_released(l, cid) then private.lesson_opens(l, cid) end,
        'open', (op and private.lesson_released(l, cid)) or l.free,
        'video', case when (op and private.lesson_released(l, cid)) or l.free then l.video_url end,
        'body', case when (op and private.lesson_released(l, cid)) or l.free then l.body end,
        'files', case when (op and private.lesson_released(l, cid)) or l.free then l.files else '[]'::jsonb end,
        'has_video', l.video_url is not null, 'n_files', jsonb_array_length(l.files),
        'done', exists (select 1 from public.course_progress pr where pr.lesson_id = l.id and pr.customer_id = cid and pr.done)) order by l.sort, l.created_at), '[]'::jsonb)
      from public.course_lessons l where l.course_id = c.id and not l.removed));
end $$;
revoke all on function public.course_view_as(uuid, uuid) from public, anon;
grant execute on function public.course_view_as(uuid, uuid) to authenticated;
