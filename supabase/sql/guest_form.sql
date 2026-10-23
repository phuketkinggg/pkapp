-- The guest form: a web page from a link (no app, no sign in) where a guest fills in their profile before they arrive:
-- photo, name, where they are from, Muay Thai experience (months or years), their own level, goals, health and worries.
-- It saves to the same customer file as the app survey (customer_intake). Every booking gets its link straight away.
-- The evening before they arrive, coaches and managers get an email with each guest's photo, name and level.

create or replace function private.prearrival_clean(p jsonb) returns jsonb language sql immutable set search_path='' as $f$
  select jsonb_strip_nulls(jsonb_build_object(
    'name', nullif(left(btrim(coalesce(p->>'name','')), 80), ''),
    'location', nullif(left(btrim(coalesce(p->>'location','')), 120), ''),
    'self_level', case when p->>'self_level' in ('complete','beginner','intermediate','advanced') then p->>'self_level' end,
    'exp_n', case when p->>'exp_n' ~ '^\d{1,2}(\.\d)?$' then (p->>'exp_n')::numeric end,
    'exp_unit', case when p->>'exp_unit' in ('months','years') then p->>'exp_unit' end,
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

create or replace function private.intake_save(v uuid, p jsonb, p_done boolean) returns void language plpgsql security definer set search_path='' as $f$
declare r public.prearrival; nx date; a jsonb := private.prearrival_clean(coalesce(p,'{}'::jsonb)); cfg jsonb := private.prearrival_cfg();
  t date := private.bkk_today(); arr date; lvl text; gk text; gid uuid; m uuid; c public.customers; goals text; ph text := nullif(p->>'photo',''); early boolean;
  cid uuid; cstart date;
begin
  if v is null then raise exception 'Sign in first.'; end if;
  -- the level they picked for themselves also sets the plan level, when they did not pick one in the app
  if a->>'level' is null and a ? 'self_level' then
    a := a || jsonb_build_object('level', case a->>'self_level' when 'complete' then 'new' when 'beginner' then 'under6m' when 'intermediate' then '6m2y' else '2y' end);
  end if;
  select * into r from public.prearrival where customer_id=v for update;
  if r.customer_id is null then
    select s.check_in into nx from public.stays s where s.customer_id=v and s.status='booked' and s.hold_until is null and s.check_in >= private.bkk_today() order by s.check_in limit 1;
    perform private.prearrival_upsert(v, nx, null, null); select * into r from public.prearrival where customer_id=v for update;
  end if;
  -- their name, as they wrote it
  if a ? 'name' and char_length(a->>'name') >= 2 then update public.customers set name = a->>'name' where id = v and name is distinct from a->>'name'; end if;
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
end $f$;
revoke all on function private.intake_save(uuid, jsonb, boolean) from public, anon, authenticated;

create or replace function public.prearrival_save(p jsonb, p_done boolean) returns jsonb language plpgsql security definer set search_path='' as $f$
begin
  if private.customer_id() is null then raise exception 'Sign in first.'; end if;
  perform private.intake_save(private.customer_id(), p, p_done);
  return public.prearrival_mine();
end $f$;
revoke all on function public.prearrival_save(jsonb, boolean) from public, anon;
grant execute on function public.prearrival_save(jsonb, boolean) to authenticated;

-- the form page, by its link
create or replace function public.guest_form_get(p_token text) returns jsonb language plpgsql stable security definer set search_path='' as $f$
declare r public.prearrival; c public.customers; ci public.customer_intake;
begin
  select * into r from public.prearrival where token = p_token;
  if r.customer_id is null or (r.expires_at < now() and coalesce(r.arrival, private.bkk_today()) < private.bkk_today() - 7) then return null; end if;
  select * into c from public.customers where id = r.customer_id;
  select * into ci from public.customer_intake where customer_id = r.customer_id;
  return jsonb_build_object('customer_id', c.id, 'name', c.name, 'arrival', r.arrival,
    'room', (select rm.name from public.stays s join public.rooms rm on rm.id = s.room_id where s.id = r.stay_id),
    'answers', case when r.answers = '{}'::jsonb then coalesce(ci.answers, '{}'::jsonb) - 'arrival' - 'start_on' else r.answers end,
    'photo', ci.photo_path, 'done_at', coalesce(r.done_at, ci.done_at));
end $f$;
revoke all on function public.guest_form_get(text) from public, anon, authenticated;
grant execute on function public.guest_form_get(text) to service_role;

create or replace function public.guest_form_save(p_token text, p jsonb, p_done boolean) returns jsonb language plpgsql security definer set search_path='' as $f$
declare r public.prearrival;
begin
  select * into r from public.prearrival where token = p_token;
  if r.customer_id is null or (r.expires_at < now() and coalesce(r.arrival, private.bkk_today()) < private.bkk_today() - 7) then raise exception 'This link has expired. Ask us for a new one.'; end if;
  if r.opened_at is null then update public.prearrival set opened_at = now() where customer_id = r.customer_id; end if;
  perform private.intake_save(r.customer_id, p, p_done);
  return public.guest_form_get(p_token);
end $f$;
revoke all on function public.guest_form_save(text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.guest_form_save(text, jsonb, boolean) to service_role;

-- every booking gets its form link straight away (room bookings made in the app, on the website, or from the booking sites)
create or replace function private.stay_form_link() returns trigger language plpgsql security definer set search_path='' as $f$
begin
  if new.status = 'booked' and new.hold_until is null and new.check_in >= private.bkk_today()
     and (tg_op = 'INSERT' or old.hold_until is not null or old.status is distinct from 'booked' or old.check_in is distinct from new.check_in)
     and not coalesce((select is_agency from public.customers where id = new.customer_id), true) then
    perform private.prearrival_upsert(new.customer_id, new.check_in, new.id, null);
  end if;
  return null;
end $f$;
drop trigger if exists stays_form_link on public.stays;
create trigger stays_form_link after insert or update of status, hold_until, check_in on public.stays for each row execute function private.stay_form_link();

-- the booking page shows the form button once the stay is paid
create or replace function public.web_booking_status(p_stay uuid) returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('paid', coalesce(s.app_paid_thb,0) > 0 or s.settled or (s.hold_until is null and s.status <> 'cancelled' and exists (select 1 from public.pay_claims pc where pc.kind = 'stay' and pc.ref_id = s.id and pc.status = 'confirmed')),
    'held', s.hold_until is not null and s.hold_until > now(), 'held_until', s.hold_until, 'cancelled', s.status = 'cancelled',
    'checking', exists (select 1 from public.pay_claims pc where pc.kind = 'stay' and pc.ref_id = s.id and pc.status = 'waiting'),
    'rejected', exists (select 1 from public.pay_claims pc where pc.kind = 'stay' and pc.ref_id = s.id and pc.status = 'rejected'),
    'room', r.name, 'from', s.check_in, 'to', s.check_out, 'price', s.room_price_thb, 'total', private.web_stay_total(s.id),
    'form', case when s.hold_until is null and s.status <> 'cancelled' then (select p.token from public.prearrival p where p.customer_id = s.customer_id and p.done_at is null) end)
  from public.stays s join public.rooms r on r.id = s.room_id where s.id = p_stay and s.external_id like 'web:%'
$f$;

-- coaches and managers see the form link for each guest (to WhatsApp it)
do $$ declare d text := pg_get_functiondef('public.prearrival_list()'::regprocedure); begin
  if position('''token''' in d) = 0 then
    d := replace(d, $a$'answers', p.answers, 'photo', ci.photo_path,$a$, $b$'answers', p.answers, 'photo', ci.photo_path, 'token', p.token,$b$);
    if position('''token''' in d) = 0 then raise exception 'prearrival_list patch did not apply'; end if;
    execute d;
  end if;
end $$;

-- the evening brief: everyone arriving on a day, with what coaches need
create or replace function public.coach_brief(p_day date) returns jsonb language sql stable security definer set search_path='' as $f$
  select jsonb_build_object('day', p_day,
    'guests', coalesce((select jsonb_agg(x order by x->>'name') from (
      select distinct on (c.id) jsonb_build_object('customer_id', c.id, 'name', c.name,
        'room', (select rm.name from public.rooms rm where rm.id = s.room_id), 'photo', ci.photo_path,
        'answers', coalesce(nullif(p.answers, '{}'::jsonb), ci.answers, '{}'::jsonb), 'done', coalesce(p.done_at, ci.done_at) is not null) x
      from public.customers c
      left join public.stays s on s.customer_id = c.id and s.status = 'booked' and s.check_in = p_day
      left join public.prearrival p on p.customer_id = c.id
      left join public.customer_intake ci on ci.customer_id = c.id
      where not coalesce(c.is_agency, false) and (s.id is not null or p.arrival = p_day)
      order by c.id) z), '[]'::jsonb),
    'to', coalesce((select jsonb_agg(distinct lower(btrim(st.email))) from public.staff st where st.active and st.role in ('coach','manager') and coalesce(st.email,'') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'), '[]'::jsonb))
$f$;
revoke all on function public.coach_brief(date) from public, anon, authenticated;
grant execute on function public.coach_brief(date) to service_role;

-- 18:00 Bangkok every day
select cron.unschedule('coach-brief') where exists (select 1 from cron.job where jobname = 'coach-brief');
select cron.schedule('coach-brief', '0 11 * * *', $c$
  select net.http_post(
    url := 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1/prearrival',
    headers := jsonb_build_object('Content-Type','application/json','x-sync-token',(select value from private.sync_settings where key='sync_token')),
    body := '{"mode":"brief"}'::jsonb,
    timeout_milliseconds := 120000)
$c$);
