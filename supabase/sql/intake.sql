-- The "About you" survey, early app access and the Muay Thai foundations course.
-- Everyone who joins the app gets the survey (not only invited guests). Their answers are kept on their customer profile (customer_intake),
-- coaches see them with a photo under Arriving soon and in Coaching, and beginners get a 2 week foundations course released one day at a time.
-- Early app access (a booking extra or a package covering "App early access") sends the invite as soon as they book and starts the course straight away.

create table if not exists public.customer_intake(
  customer_id uuid primary key references public.customers(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  photo_path text,
  done_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.customer_intake enable row level security;
revoke all on public.customer_intake from anon, authenticated;

-- coaches can see profile photos of anyone (they need to recognise guests), other private files only for their own clients
create or replace function private.coach_path_ok(p_name text) returns boolean language plpgsql stable security definer set search_path to '' as $function$
declare v text := substring(p_name from '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/');
begin
  if v is null then return false; end if;
  if split_part(p_name, '/', 2) = 'profile' and private.coach_staff() then return true; end if;
  return private.customer_id() = v::uuid or private.coach_can(v::uuid);
end $function$;

create or replace function private.early_access(p_customer uuid) returns boolean language sql stable security definer set search_path to '' as $f$
  select exists (select 1 from public.purchases p where p.customer_id = p_customer and not coalesce(p.cancelled, false) and p.refunded_at is null
    and ('App early access' = any(coalesce(p.covers, '{}')) or p.package_name ilike '%early app access%' or p.package_name ilike '%app early access%'))
$f$;

create or replace function private.prearrival_clean(p jsonb) returns jsonb language sql immutable set search_path='' as $f$
  select jsonb_strip_nulls(jsonb_build_object(
    'arrival', case when p->>'arrival' ~ '^\d{4}-\d{2}-\d{2}$' then p->>'arrival' end,
    'start_on', case when p->>'start_on' ~ '^\d{4}-\d{2}-\d{2}$' then p->>'start_on' end,
    'main', case when p->>'main' in ('fight','weight','fitness','technique','reset','other') then p->>'main' end,
    'main_other', nullif(left(btrim(coalesce(p->>'main_other','')), 200), ''),
    'weight_kg', case when p->>'weight_kg' ~ '^\d{2,3}(\.\d)?$' and (p->>'weight_kg')::numeric between 30 and 250 then (p->>'weight_kg')::numeric end,
    'height_cm', case when p->>'height_cm' ~ '^\d{3}$' and (p->>'height_cm')::int between 120 and 230 then (p->>'height_cm')::int end,
    'target_kg', case when p->>'target_kg' ~ '^\d{2,3}(\.\d)?$' and (p->>'target_kg')::numeric between 30 and 250 then (p->>'target_kg')::numeric end,
    'fitness', case when p->>'fitness' ~ '^[1-5]$' then (p->>'fitness')::int end,
    'train_now', case when p->>'train_now' in ('none','1-2','3-4','5+') then p->>'train_now' end,
    'level', case when p->>'level' in ('new','under6m','6m2y','2y','fought') then p->>'level' end,
    'fights', case when p->>'fights' ~ '^\d{1,3}$' then (p->>'fights')::int end,
    'other_training', case when jsonb_typeof(p->'other_training')='array' then (select jsonb_agg(g) from (select distinct g from jsonb_array_elements_text(p->'other_training') g
       where g in ('boxing','kickboxing','mma','bjj','wrestling','weights','running','crossfit','yoga','team','none')) z) end,
    'other_training_note', nullif(left(btrim(coalesce(p->>'other_training_note','')), 300), ''),
    'goals', case when jsonb_typeof(p->'goals')='array' then (select jsonb_agg(g) from (select distinct g from jsonb_array_elements_text(p->'goals') g
       where g in ('technique','fitness','weight','fight','confidence','reset')) z) end,
    'win', nullif(left(btrim(coalesce(p->>'win','')), 600), ''),
    'fears', nullif(left(btrim(coalesce(p->>'fears','')), 800), ''),
    'mind', nullif(left(btrim(coalesce(p->>'mind','')), 1000), ''),
    'injury', case when p->>'injury' in ('no','yes') then p->>'injury' end,
    'injury_where', nullif(left(btrim(coalesce(p->>'injury_where','')), 200), ''),
    'injury_note', nullif(left(btrim(coalesce(p->>'injury_note','')), 600), ''),
    'allergies', nullif(left(btrim(coalesce(p->>'allergies','')), 300), ''),
    'sessions', case when p->>'sessions' in ('1','2','unsure') then p->>'sessions' end,
    'privates', case when p->>'privates' in ('yes','maybe','no') then p->>'privates' end,
    'food', nullif(left(btrim(coalesce(p->>'food','')), 300), ''),
    'notes', nullif(left(btrim(coalesce(p->>'notes','')), 600), '')))
$f$;

-- the member's own form. Anyone in the app who has not done it yet gets one (with their next booked stay as the arrival, if any)
create or replace function public.prearrival_mine() returns jsonb language plpgsql security definer set search_path='' as $f$
declare v uuid := private.customer_id(); r public.prearrival; cfg jsonb := private.prearrival_cfg(); t date := private.bkk_today(); nx date; ci public.customer_intake;
begin
  if v is null then return null; end if;
  select * into ci from public.customer_intake where customer_id=v;
  select * into r from public.prearrival where customer_id=v;
  if r.customer_id is null then
    if ci.done_at is not null then return null; end if;
    select s.check_in into nx from public.stays s where s.customer_id=v and s.status='booked' and s.hold_until is null and s.check_in >= t order by s.check_in limit 1;
    r := private.prearrival_upsert(v, nx, null, null);
  end if;
  if r.arrival is not null and r.arrival < t - 3 and ci.done_at is not null then return null; end if;
  if r.arrival is null and r.done_at is not null and r.done_at < now() - interval '30 days' then return null; end if;
  if r.opened_at is null then update public.prearrival set opened_at=now() where customer_id=v; end if;
  return jsonb_build_object('customer_id', v, 'arrival', r.arrival, 'days', case when r.arrival is not null then r.arrival - t end,
    'answers', case when r.answers = '{}'::jsonb and ci.answers is not null then ci.answers - 'arrival' - 'start_on' else r.answers end,
    'done_at', r.done_at, 'photo', ci.photo_path, 'early', private.early_access(v),
    'video_url', nullif(cfg->>'video_url',''), 'video_title', coalesce(nullif(cfg->>'video_title',''), 'Meet your coaches'),
    'group', (select g.name from public.group_members m join public.action_groups g on g.id=m.group_id where m.id=r.group_member and not m.removed));
end $f$;
revoke all on function public.prearrival_mine() from public, anon;
grant execute on function public.prearrival_mine() to authenticated;

create or replace function public.prearrival_save(p jsonb, p_done boolean) returns jsonb language plpgsql security definer set search_path='' as $f$
declare v uuid := private.customer_id(); r public.prearrival; a jsonb := private.prearrival_clean(coalesce(p,'{}'::jsonb)); cfg jsonb := private.prearrival_cfg();
  t date := private.bkk_today(); arr date; lvl text; gk text; gid uuid; m uuid; c public.customers; goals text; ph text := nullif(p->>'photo',''); early boolean;
  cid uuid; cstart date;
begin
  if v is null then raise exception 'Sign in first.'; end if;
  select * into r from public.prearrival where customer_id=v for update;
  if r.customer_id is null then perform public.prearrival_mine(); select * into r from public.prearrival where customer_id=v for update; end if;
  if r.customer_id is null then raise exception 'There is no form for you right now.'; end if;
  if ph is not null and ph !~ ('^' || v::text || '/profile/[a-z0-9]{6,40}\.jpg$') then raise exception 'Photo upload did not match. Try again.'; end if;
  arr := coalesce(r.arrival, nullif(a->>'arrival','')::date);
  if arr is not null and (arr < t - 400 or arr > t + 400) then raise exception 'Check your arrival date.'; end if;
  if a->>'start_on' is not null and ((a->>'start_on')::date < t - 400 or (a->>'start_on')::date > t + 400) then raise exception 'Check your first training day.'; end if;
  update public.prearrival set answers=a, arrival=arr, updated_at=now() where customer_id=v;
  insert into public.customer_intake(customer_id, answers, photo_path, updated_at) values (v, a, ph, now())
    on conflict (customer_id) do update set answers=excluded.answers, photo_path=coalesce(excluded.photo_path, public.customer_intake.photo_path), updated_at=now();
  if p_done then
    if a->>'level' is null then raise exception 'Choose your Muay Thai level.'; end if;
    update public.customer_intake set done_at=coalesce(done_at, now()) where customer_id=v;
  end if;
  if p_done and r.done_at is null then
    select * into c from public.customers where id=v;
    early := private.early_access(v);
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
    lvl := a->>'level';
    -- the countdown group (only with an arrival date coming up): day 1 is 14 days before arrival, day 15 is arrival day
    gk := case when lvl='fought' or a->>'main'='fight' or (coalesce(a->'goals','[]'::jsonb) ? 'fight' and lvl in ('6m2y','2y')) then 'fight' when lvl in ('new','under6m') then 'beginner' else 'experienced' end;
    begin gid := nullif(cfg->'groups'->>gk,'')::uuid; exception when others then gid := null; end;
    if arr is not null and arr >= t and gid is not null and exists (select 1 from public.action_groups where id=gid and not removed)
       and not exists (select 1 from public.group_members where group_id=gid and customer_id=v and not removed) then
      insert into public.group_members(group_id, customer_id, start_on) values (gid, v, arr - 14) returning id into m;
      perform private.group_apply(m);
    end if;
    -- beginners (and anyone with early access) get the foundations course: one lesson a day, finishing as they arrive, or from today with early access
    begin cid := nullif(cfg->'groups'->>'course','')::uuid; exception when others then cid := null; end;
    if cid is not null and (lvl in ('new','under6m') or early) and exists (select 1 from public.action_groups where id=cid and not removed)
       and not exists (select 1 from public.group_members where group_id=cid and customer_id=v and not removed) then
      cstart := case when early or arr is null then t else greatest(t, arr - 14) end;
      insert into public.group_members(group_id, customer_id, start_on) values (cid, v, cstart) returning id into gid;
      perform private.group_apply(gid);
    end if;
    update public.prearrival set done_at=now(), group_member=coalesce(m, group_member) where customer_id=v;
    insert into public.notices(kind, customer_id, ref_id, title, detail) values ('prearrival', v, v,
      'About you form done: ' || c.name || coalesce(', arriving ' || to_char(arr, 'FMDD Mon'), ''),
      concat_ws('. ', case a->>'main' when 'fight' then 'Coming for fight training' when 'weight' then 'Coming for weight loss' when 'fitness' then 'Coming for fitness'
          when 'technique' then 'Coming to learn Muay Thai' when 'reset' then 'Coming to reset' when 'other' then 'Coming for: ' || coalesce(a->>'main_other','other') end,
        'Level: ' || case lvl when 'new' then 'never trained' when 'under6m' then 'under 6 months' when '6m2y' then '6 months to 2 years' when '2y' then '2 years plus' when 'fought' then 'has fought' end,
        case when goals is not null then 'Goals: ' || goals end, case when a->>'injury'='yes' then 'Injury: ' || coalesce(a->>'injury_where','yes') end,
        case when a ? 'allergies' then 'Allergies: ' || (a->>'allergies') end,
        case when a->>'privates' in ('yes','maybe') then 'Privates: ' || (a->>'privates') end));
  end if;
  return public.prearrival_mine();
end $f$;
revoke all on function public.prearrival_save(jsonb, boolean) from public, anon;
grant execute on function public.prearrival_save(jsonb, boolean) to authenticated;

-- coaches and managers: who is arriving, what they told us, and their photo
create or replace function public.prearrival_list() returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare t date := private.bkk_today();
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can see this.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'arrival' nulls last, x->>'name') from (
    select jsonb_build_object('customer_id', c.id, 'name', c.name, 'has_email', coalesce(c.email,'') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'arrival', p.arrival,
      'room', (select r.name from public.stays s join public.rooms r on r.id=s.room_id where s.id=p.stay_id),
      'web', p.order_id is not null, 'sent_at', p.sent_at, 'send_error', case when p.sent_at is null then p.send_error end, 'opened_at', p.opened_at, 'done_at', p.done_at,
      'answers', p.answers, 'photo', ci.photo_path, 'early', private.early_access(c.id),
      'group', (select g.name from public.group_members m join public.action_groups g on g.id=m.group_id where m.id=p.group_member and not m.removed)) x
    from public.prearrival p join public.customers c on c.id=p.customer_id left join public.customer_intake ci on ci.customer_id=c.id
    where (p.arrival is not null and p.arrival between t - 2 and t + 60)
       or (p.arrival is null and p.created_at > now() - interval '45 days' and (p.sent_at is not null or p.done_at is not null))
    union all
    select jsonb_build_object('customer_id', c.id, 'name', c.name, 'has_email', coalesce(c.email,'') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'arrival', s.check_in,
      'room', (select r.name from public.rooms r where r.id=s.room_id), 'web', false, 'sent_at', null, 'opened_at', null, 'done_at', ci.done_at,
      'answers', coalesce(ci.answers, '{}'::jsonb), 'photo', ci.photo_path, 'early', private.early_access(c.id), 'group', null, 'not_sent', true)
    from (select distinct on (customer_id) * from public.stays where status='booked' and check_in between t and t + 30 order by customer_id, check_in) s
    join public.customers c on c.id=s.customer_id left join public.customer_intake ci on ci.customer_id=c.id
    where not coalesce(c.is_agency,false)
      and not exists (select 1 from public.prearrival p where p.customer_id=s.customer_id and (p.arrival is null or p.arrival >= t - 30))
  ) q), '[]'::jsonb);
end $f$;
revoke all on function public.prearrival_list() from public, anon;
grant execute on function public.prearrival_list() to authenticated;

-- one customer's answers, for the Coaching and customer pages
create or replace function public.customer_intake_get(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare ci public.customer_intake; pa public.prearrival;
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can see this.'; end if;
  select * into ci from public.customer_intake where customer_id=p_customer;
  select * into pa from public.prearrival where customer_id=p_customer;
  if ci.customer_id is null and pa.customer_id is null then return null; end if;
  return jsonb_build_object('answers', coalesce(ci.answers, pa.answers, '{}'::jsonb), 'photo', ci.photo_path, 'done_at', coalesce(ci.done_at, pa.done_at),
    'updated_at', ci.updated_at, 'arrival', pa.arrival, 'early', private.early_access(p_customer));
end $f$;
revoke all on function public.customer_intake_get(uuid) from public, anon;
grant execute on function public.customer_intake_get(uuid) to authenticated;

-- the email job: early access guests get the invite as soon as they book, everyone else up to 14 days before arrival
do $$ declare d text := pg_get_functiondef('public.prearrival_due()'::regprocedure); begin
  if position('early_access' in d) = 0 then
    d := replace(d, 'where s.status=''booked'' and s.hold_until is null and s.check_in between t and t + 14 and s.created_at >= since',
      'where s.status=''booked'' and s.hold_until is null and s.created_at >= since and (s.check_in between t and t + 14 or (s.check_in > t and private.early_access(s.customer_id)))');
    -- people already in the app (the form opened there) do not need the email
    d := replace(d, 'from public.prearrival where sent_at is null and tries < 3', 'from public.prearrival where sent_at is null and opened_at is null and tries < 3');
    if position('early_access' in d) = 0 or position('opened_at is null and tries' in d) = 0 then raise exception 'prearrival_due patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- the 2 week foundations course (a group: day 1 is the day they start). Steps are notes until the videos are added in Coaching, Action groups.
create or replace function private.course_seed() returns void language plpgsql security definer set search_path='' as $f$
declare cfg jsonb; gid uuid;
begin
  select case when value ~ '^\s*\{' then value::jsonb else '{}'::jsonb end into cfg from public.app_settings where key='prearrival';
  cfg := coalesce(cfg, '{}'::jsonb);
  select id into gid from public.action_groups where name='Muay Thai foundations: 2 week course' and not removed limit 1;
  if gid is null then
    insert into public.action_groups(name, notes, items) values ('Muay Thai foundations: 2 week course',
      'One short lesson a day for 14 days: fitness, stretching and the basic moves. Beginners get it in the two weeks before they arrive, early access guests from the day they join. Swap each note for your video (kind Video).',
      '[
        {"id":"mf-01","kind":"note","at_mode":"day","at_n":1,"title":"Day 1: Welcome to Muay Thai","text":"One short lesson a day for the next two weeks. 15 to 20 minutes is enough. By the time you arrive you will know your stance, the basic strikes and what a class feels like.\n\nToday: watch, then stand in front of a mirror and copy the stance for 2 minutes."},
        {"id":"mf-stretch","kind":"habit","at_mode":"day","at_n":1,"title":"Stretch for 10 minutes","text":"Hips, hamstrings, calves and shoulders. It makes kicking much easier.","habit":{"freq":"daily","days":[],"times":1,"weeks":2}},
        {"id":"mf-02","kind":"note","at_mode":"day","at_n":2,"title":"Day 2: Stance and guard","text":"- Feet shoulder width apart, lead foot forward, back heel slightly up\n- Hands up by your cheeks, elbows in\n- Chin down, eyes forward\n\nHold it for 3 rounds of 1 minute, relax between rounds."},
        {"id":"mf-03","kind":"note","at_mode":"day","at_n":3,"title":"Day 3: Footwork","text":"Step forward, back and to each side without crossing your feet, and keep your guard up.\n\n3 rounds of 2 minutes, 1 minute rest."},
        {"id":"mf-04","kind":"note","at_mode":"day","at_n":4,"title":"Day 4: The jab","text":"Lead hand straight out and straight back to your cheek. Turn the fist over at the end. The other hand stays home.\n\n3 rounds of 2 minutes: footwork plus jab."},
        {"id":"mf-05","kind":"note","at_mode":"day","at_n":5,"title":"Day 5: The cross","text":"Rear hand straight out, turn the back foot and hip into it, and bring it straight back.\n\n3 rounds: jab, cross, step back."},
        {"id":"mf-06","kind":"note","at_mode":"day","at_n":6,"title":"Day 6: Fitness base","text":"Skip or jog on the spot for 3 rounds of 3 minutes, then 3 sets of 10 squats, 10 push ups and a 30 second plank. Go at your own pace."},
        {"id":"mf-07","kind":"note","at_mode":"day","at_n":7,"title":"Day 7: Rest and stretch","text":"No training today. Take 20 minutes for a full stretch: hips, hamstrings, groin, calves and shoulders."},
        {"id":"mf-08","kind":"note","at_mode":"day","at_n":8,"title":"Day 8: The teep (push kick)","text":"Lift the knee, push the ball of the foot through the target, and put the foot back down in your stance. Hands stay up.\n\n3 rounds: jab, cross, teep."},
        {"id":"mf-09","kind":"note","at_mode":"day","at_n":9,"title":"Day 9: The roundhouse kick","text":"Step out at an angle, turn the standing foot, swing the leg through and hit with the shin. Arm on the kicking side swings down for balance.\n\nSlow and controlled, 10 each side, 3 sets."},
        {"id":"mf-10","kind":"note","at_mode":"day","at_n":10,"title":"Day 10: Knees","text":"Hands reach up as if holding a head, pull down, drive the knee up and push the hips forward.\n\n3 rounds of 1 minute, change sides each round."},
        {"id":"mf-11","kind":"note","at_mode":"day","at_n":11,"title":"Day 11: Elbows","text":"Short and sharp: horizontal elbow, the hand stays close to your head, turn the hip and shoulder into it.\n\n3 rounds: jab, cross, elbow."},
        {"id":"mf-12","kind":"note","at_mode":"day","at_n":12,"title":"Day 12: Rest and stretch","text":"Rest day. 20 minutes of stretching, and drink plenty of water."},
        {"id":"mf-13","kind":"note","at_mode":"day","at_n":13,"title":"Day 13: Putting it together","text":"Shadow box 4 rounds of 2 minutes using everything: jab, cross, teep, kick, knee and elbow. Relaxed, guard up, breathe out on every strike."},
        {"id":"mf-14","kind":"note","at_mode":"day","at_n":14,"title":"Day 14: Ready for camp","text":"Well done. You know the basics, so on day one the coaches can build on them instead of starting from zero. Easy day today: a light stretch and an early night."}
      ]'::jsonb) returning id into gid;
  end if;
  cfg := jsonb_set(cfg, '{groups}', coalesce(cfg->'groups','{}'::jsonb) || jsonb_build_object('course', coalesce(nullif(cfg->'groups'->>'course',''), gid::text)));
  update public.app_settings set value=cfg::text, updated_at=now() where key='prearrival';
end $f$;
revoke all on function private.course_seed() from public, anon, authenticated;
select private.course_seed();

-- the booking page extra (off until a manager sets the price and turns it on in Settings, Room prices)
update public.app_settings set value = jsonb_set(value::jsonb, '{extras}', coalesce(value::jsonb->'extras','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
    'id','early','cat','training','kind','qty','max',1,'name','Early app access','price',990,'off',true,'covers',jsonb_build_array('App early access'),
    'note','Start in the app as soon as you book: the 2 week Muay Thai foundations course, a plan built from your answers, habit and food tracking, and your coaches in the app.')))::text,
  updated_at = now()
where key = 'room_rates' and value ~ '^\s*\{' and not exists (select 1 from jsonb_array_elements(coalesce(value::jsonb->'extras','[]'::jsonb)) e where e->>'id' = 'early');
