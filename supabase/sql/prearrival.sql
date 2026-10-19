-- Get ready for camp: guests start in the app before they arrive.
-- An email goes out up to 14 days before arrival (room guests and online package buyers) with a one tap link into the app.
-- They fill in a short form (level, goals, weight, injuries), are placed in a countdown group, and coaches see them under Arriving soon.

create table if not exists public.prearrival(
  customer_id uuid primary key references public.customers(id) on delete cascade,
  arrival date,
  stay_id uuid,
  order_id uuid,
  token text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  expires_at timestamptz not null default now() + interval '45 days',
  sent_at timestamptz, sent_to text, tries int not null default 0, send_error text,
  opened_at timestamptz, done_at timestamptz,
  answers jsonb not null default '{}'::jsonb,
  group_member uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.prearrival enable row level security;
revoke all on public.prearrival from anon, authenticated;
create index if not exists prearrival_arrival on public.prearrival(arrival);

alter table public.notices drop constraint if exists notices_kind_check2;
alter table public.notices add constraint notices_kind_check2 check (kind = any (array['signup','first_signin','package','stay','refund','shop','prearrival']));

insert into public.app_settings(key, value) values ('prearrival', '{"auto":false,"video_url":"","video_title":"Meet your coaches","groups":{}}')
  on conflict (key) do nothing;

create or replace function private.prearrival_cfg() returns jsonb language sql stable security definer set search_path='' as $f$
  select coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key='prearrival'), '{}'::jsonb)
$f$;

-- start (or restart) the invite for a customer; an old finished one is reset for the new trip
create or replace function private.prearrival_upsert(p_customer uuid, p_arrival date, p_stay uuid, p_order uuid) returns public.prearrival
language plpgsql security definer set search_path='' as $f$
declare r public.prearrival; t date := private.bkk_today();
begin
  select * into r from public.prearrival where customer_id=p_customer for update;
  if r.customer_id is null then
    insert into public.prearrival(customer_id, arrival, stay_id, order_id, expires_at)
      values (p_customer, p_arrival, p_stay, p_order, (coalesce(p_arrival, t) + 21)::timestamptz) returning * into r;
  elsif r.arrival is not null and r.arrival < t - 30 or (r.arrival is null and r.created_at < now() - interval '60 days') then
    update public.prearrival set arrival=p_arrival, stay_id=p_stay, order_id=p_order, sent_at=null, sent_to=null, tries=0, send_error=null, opened_at=null, done_at=null,
      answers='{}'::jsonb, group_member=null, token=replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
      expires_at=(coalesce(p_arrival, t) + 21)::timestamptz, created_at=now(), updated_at=now() where customer_id=p_customer returning * into r;
  else
    update public.prearrival set arrival=coalesce(p_arrival, arrival), stay_id=coalesce(p_stay, stay_id), order_id=coalesce(p_order, order_id),
      expires_at=greatest(expires_at, (coalesce(p_arrival, arrival, t) + 21)::timestamptz), updated_at=now() where customer_id=p_customer returning * into r;
  end if;
  return r;
end $f$;

-- the email job: new room bookings arriving within 14 days and paid website packages starting within 14 days (or with no date)
create or replace function public.prearrival_due() returns jsonb language plpgsql security definer set search_path='' as $f$
declare cfg jsonb := private.prearrival_cfg(); since timestamptz; t date := private.bkk_today(); x record;
begin
  if coalesce((cfg->>'auto')::boolean, false) is not true then return '[]'::jsonb; end if;
  since := coalesce(nullif(cfg->>'since','')::timestamptz, now());
  for x in select distinct on (s.customer_id) s.customer_id, s.check_in, s.id from public.stays s join public.customers c on c.id=s.customer_id
      where s.status='booked' and s.hold_until is null and s.check_in between t and t + 14 and s.created_at >= since
        and not coalesce(c.is_agency,false) and c.email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        and not exists (select 1 from public.prearrival p where p.customer_id=s.customer_id and (p.arrival is null or p.arrival >= t - 30))
      order by s.customer_id, s.check_in loop
    perform private.prearrival_upsert(x.customer_id, x.check_in, x.id, null);
  end loop;
  for x in select distinct on (w.customer_id) w.customer_id, w.start_on, w.id from public.web_pkg_orders w join public.customers c on c.id=w.customer_id
      where w.status='paid' and w.paid_at >= since and w.package_id is not null and (w.start_on is null or w.start_on between t and t + 14)
        and c.email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        and not exists (select 1 from public.prearrival p where p.customer_id=w.customer_id and (p.arrival is null or p.arrival >= t - 30))
      order by w.customer_id, w.paid_at desc loop
    perform private.prearrival_upsert(x.customer_id, x.start_on, null, x.id);
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('customer_id', p.customer_id, 'name', c.name, 'email', lower(c.email), 'arrival', p.arrival, 'token', p.token))
    from (select * from public.prearrival where sent_at is null and tries < 3 and expires_at > now() and created_at >= since order by created_at limit 20) p
    join public.customers c on c.id=p.customer_id), '[]'::jsonb);
end $f$;
revoke all on function public.prearrival_due() from public, anon, authenticated;
grant execute on function public.prearrival_due() to service_role;

-- a coach or manager sends (or re-sends) the invite by hand
create or replace function public.prearrival_invite(p_customer uuid, p_arrival date) returns jsonb language plpgsql security definer set search_path='' as $f$
declare c public.customers; r public.prearrival; st uuid;
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can send this.'; end if;
  select * into c from public.customers where id=p_customer;
  if c.id is null then raise exception 'Customer not found.'; end if;
  if coalesce(c.email,'') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Add their email first (Customers, Edit).'; end if;
  if exists (select 1 from public.staff s where lower(s.email)=lower(c.email)) then raise exception 'That email belongs to a staff login.'; end if;
  select id into st from public.stays where customer_id=p_customer and status in ('booked','in') and check_in >= coalesce(p_arrival, private.bkk_today()) - 1 order by check_in limit 1;
  r := private.prearrival_upsert(p_customer, p_arrival, st, null);
  return jsonb_build_object('customer_id', c.id, 'name', c.name, 'email', lower(c.email), 'arrival', r.arrival, 'token', r.token);
end $f$;
revoke all on function public.prearrival_invite(uuid, date) from public, anon;
grant execute on function public.prearrival_invite(uuid, date) to authenticated;

-- the email link: a valid token gives back who to sign in (the edge function makes the sign in)
create or replace function public.prearrival_claim(p_token text) returns jsonb language plpgsql security definer set search_path='' as $f$
declare r public.prearrival; c public.customers;
begin
  if coalesce(p_token,'') !~ '^[0-9a-f]{64}$' then return null; end if;
  select * into r from public.prearrival where token=p_token and expires_at > now();
  if r.customer_id is null then return null; end if;
  select * into c from public.customers where id=r.customer_id;
  if exists (select 1 from public.staff s where lower(s.email)=lower(c.email) or (c.user_id is not null and s.user_id=c.user_id)) then return null; end if;
  update public.prearrival set opened_at=coalesce(opened_at, now()) where customer_id=r.customer_id;
  return jsonb_build_object('customer_id', c.id, 'email', lower(c.email), 'user_id', c.user_id, 'name', c.name);
end $f$;
revoke all on function public.prearrival_claim(text) from public, anon, authenticated;
grant execute on function public.prearrival_claim(text) to service_role;

-- the member's own form
create or replace function public.prearrival_mine() returns jsonb language plpgsql security definer set search_path='' as $f$
declare v uuid := private.customer_id(); r public.prearrival; cfg jsonb := private.prearrival_cfg(); t date := private.bkk_today();
begin
  if v is null then return null; end if;
  select * into r from public.prearrival where customer_id=v;
  if r.customer_id is null then return null; end if;
  if r.arrival is not null and r.arrival < t - 3 then return null; end if;
  if r.arrival is null and r.done_at is not null and r.done_at < now() - interval '30 days' then return null; end if;
  if r.opened_at is null then update public.prearrival set opened_at=now() where customer_id=v; end if;
  return jsonb_build_object('arrival', r.arrival, 'days', case when r.arrival is not null then r.arrival - t end, 'answers', r.answers, 'done_at', r.done_at,
    'video_url', nullif(cfg->>'video_url',''), 'video_title', coalesce(nullif(cfg->>'video_title',''), 'Meet your coaches'),
    'group', (select g.name from public.group_members m join public.action_groups g on g.id=m.group_id where m.id=r.group_member and not m.removed));
end $f$;
revoke all on function public.prearrival_mine() from public, anon;
grant execute on function public.prearrival_mine() to authenticated;

create or replace function private.prearrival_clean(p jsonb) returns jsonb language sql immutable set search_path='' as $f$
  select jsonb_strip_nulls(jsonb_build_object(
    'arrival', case when p->>'arrival' ~ '^\d{4}-\d{2}-\d{2}$' then p->>'arrival' end,
    'weight_kg', case when p->>'weight_kg' ~ '^\d{2,3}(\.\d)?$' and (p->>'weight_kg')::numeric between 30 and 250 then (p->>'weight_kg')::numeric end,
    'height_cm', case when p->>'height_cm' ~ '^\d{3}$' and (p->>'height_cm')::int between 120 and 230 then (p->>'height_cm')::int end,
    'target_kg', case when p->>'target_kg' ~ '^\d{2,3}(\.\d)?$' and (p->>'target_kg')::numeric between 30 and 250 then (p->>'target_kg')::numeric end,
    'fitness', case when p->>'fitness' ~ '^[1-5]$' then (p->>'fitness')::int end,
    'train_now', case when p->>'train_now' in ('none','1-2','3-4','5+') then p->>'train_now' end,
    'level', case when p->>'level' in ('new','under6m','6m2y','2y','fought') then p->>'level' end,
    'fights', case when p->>'fights' ~ '^\d{1,3}$' then (p->>'fights')::int end,
    'goals', case when jsonb_typeof(p->'goals')='array' then (select jsonb_agg(g) from (select distinct g from jsonb_array_elements_text(p->'goals') g
       where g in ('technique','fitness','weight','fight','confidence','reset')) z) end,
    'win', nullif(left(btrim(coalesce(p->>'win','')), 600), ''),
    'injury', case when p->>'injury' in ('no','yes') then p->>'injury' end,
    'injury_where', nullif(left(btrim(coalesce(p->>'injury_where','')), 200), ''),
    'injury_note', nullif(left(btrim(coalesce(p->>'injury_note','')), 600), ''),
    'sessions', case when p->>'sessions' in ('1','2','unsure') then p->>'sessions' end,
    'privates', case when p->>'privates' in ('yes','maybe','no') then p->>'privates' end,
    'food', nullif(left(btrim(coalesce(p->>'food','')), 300), ''),
    'notes', nullif(left(btrim(coalesce(p->>'notes','')), 600), '')))
$f$;

create or replace function public.prearrival_save(p jsonb, p_done boolean) returns jsonb language plpgsql security definer set search_path='' as $f$
declare v uuid := private.customer_id(); r public.prearrival; a jsonb := private.prearrival_clean(coalesce(p,'{}'::jsonb)); cfg jsonb := private.prearrival_cfg();
  t date := private.bkk_today(); arr date; lvl text; gk text; gid uuid; m uuid; c public.customers; goals text;
begin
  if v is null then raise exception 'Sign in first.'; end if;
  select * into r from public.prearrival where customer_id=v for update;
  if r.customer_id is null then raise exception 'There is no form for you right now.'; end if;
  arr := coalesce(r.arrival, nullif(a->>'arrival','')::date);
  if arr is not null and (arr < t - 3 or arr > t + 400) then raise exception 'Check your arrival date.'; end if;
  update public.prearrival set answers=a, arrival=arr, updated_at=now() where customer_id=v;
  if p_done and r.done_at is null then
    if a->>'level' is null then raise exception 'Choose your Muay Thai level.'; end if;
    select * into c from public.customers where id=v;
    -- starting weight and goal for the coaches
    if a ? 'weight_kg' and not exists (select 1 from public.weights w where w.customer_id=v and not w.removed and w.at > now() - interval '3 days') then
      insert into public.weights(customer_id, kg, at, note) values (v, (a->>'weight_kg')::numeric, now(), 'Before arrival');
    end if;
    select string_agg(case g when 'technique' then 'learn proper technique' when 'fitness' then 'get fit' when 'weight' then 'lose weight' when 'fight' then 'fight preparation'
      when 'confidence' then 'confidence' when 'reset' then 'reset and recover' end, ', ') into goals from jsonb_array_elements_text(coalesce(a->'goals','[]'::jsonb)) g;
    if a ? 'target_kg' or goals is not null or a ? 'win' then
      insert into public.coach_goals(customer_id, kg, goal_on, note, updated_at) values (v, (a->>'target_kg')::numeric, arr,
        left(concat_ws('. ', case when goals is not null then 'Goals: ' || goals end, a->>'win'), 600), now())
      on conflict (customer_id) do update set kg=coalesce(excluded.kg, public.coach_goals.kg), goal_on=coalesce(public.coach_goals.goal_on, excluded.goal_on),
        note=coalesce(nullif(public.coach_goals.note,''), excluded.note), updated_at=now();
    end if;
    -- the countdown group: day 1 is 14 days before arrival, day 15 is arrival day
    lvl := a->>'level';
    gk := case when lvl='fought' or (coalesce(a->'goals','[]'::jsonb) ? 'fight' and lvl in ('6m2y','2y')) then 'fight' when lvl in ('new','under6m') then 'beginner' else 'experienced' end;
    begin gid := nullif(cfg->'groups'->>gk,'')::uuid; exception when others then gid := null; end;
    if gid is not null and exists (select 1 from public.action_groups where id=gid and not removed)
       and not exists (select 1 from public.group_members where group_id=gid and customer_id=v and not removed) then
      insert into public.group_members(group_id, customer_id, start_on) values (gid, v, coalesce(arr, t + 14) - 14) returning id into m;
      perform private.group_apply(m);
    end if;
    update public.prearrival set done_at=now(), group_member=coalesce(m, group_member) where customer_id=v;
    insert into public.notices(kind, customer_id, ref_id, title, detail) values ('prearrival', v, v,
      'Ready form done: ' || c.name || coalesce(', arriving ' || to_char(arr, 'FMDD Mon'), ''),
      concat_ws('. ', 'Level: ' || case lvl when 'new' then 'never trained' when 'under6m' then 'under 6 months' when '6m2y' then '6 months to 2 years' when '2y' then '2 years plus' when 'fought' then 'has fought' end,
        case when goals is not null then 'Goals: ' || goals end, case when a->>'injury'='yes' then 'Injury: ' || coalesce(a->>'injury_where','yes') end,
        case when a->>'privates' in ('yes','maybe') then 'Privates: ' || (a->>'privates') end));
  end if;
  return public.prearrival_mine();
end $f$;
revoke all on function public.prearrival_save(jsonb, boolean) from public, anon;
grant execute on function public.prearrival_save(jsonb, boolean) to authenticated;

-- coaches and managers: who is arriving, and what they told us
create or replace function public.prearrival_list() returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare t date := private.bkk_today();
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can see this.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'arrival' nulls last, x->>'name') from (
    select jsonb_build_object('customer_id', c.id, 'name', c.name, 'has_email', coalesce(c.email,'') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'arrival', p.arrival,
      'room', (select r.name from public.stays s join public.rooms r on r.id=s.room_id where s.id=p.stay_id),
      'web', p.order_id is not null, 'sent_at', p.sent_at, 'send_error', case when p.sent_at is null then p.send_error end, 'opened_at', p.opened_at, 'done_at', p.done_at,
      'answers', p.answers, 'group', (select g.name from public.group_members m join public.action_groups g on g.id=m.group_id where m.id=p.group_member and not m.removed)) x
    from public.prearrival p join public.customers c on c.id=p.customer_id
    where (p.arrival is not null and p.arrival between t - 2 and t + 60) or (p.arrival is null and p.created_at > now() - interval '45 days')
    union all
    select jsonb_build_object('customer_id', c.id, 'name', c.name, 'has_email', coalesce(c.email,'') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'arrival', s.check_in,
      'room', (select r.name from public.rooms r where r.id=s.room_id), 'web', false, 'sent_at', null, 'opened_at', null, 'done_at', null, 'answers', '{}'::jsonb, 'group', null, 'not_sent', true)
    from (select distinct on (customer_id) * from public.stays where status='booked' and check_in between t and t + 30 order by customer_id, check_in) s
    join public.customers c on c.id=s.customer_id
    where not coalesce(c.is_agency,false)
      and not exists (select 1 from public.prearrival p where p.customer_id=s.customer_id and (p.arrival is null or p.arrival >= t - 30))
  ) q), '[]'::jsonb);
end $f$;
revoke all on function public.prearrival_list() from public, anon;
grant execute on function public.prearrival_list() to authenticated;
