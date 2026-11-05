-- Course welcome email (feature course_welcome): when someone gets an online course (bought on the website, with a package or a stay,
-- or given at the desk), they get one email: how to get the app and sign in, where the course is, and what opens on which day.
-- Each course has its own wording (courses.welcome: on, subject, body) with {words} filled in. The email goes in the email queue
-- (sent_emails, sent within 10 minutes by the outreach email job). The app address is a setting (app_settings app_url), saved from the app.

alter table public.courses add column if not exists welcome jsonb;

create or replace function private.course_welcome_text(p_course uuid, p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare c public.courses%rowtype; cu public.customers%rowtype; w jsonb; app text; st jsonb; sched text; login text; biz text; subj text; body text; first text; store text;
begin
  select * into c from public.courses where id = p_course; select * into cu from public.customers where id = p_customer;
  if c.id is null or cu.id is null then return null; end if;
  w := coalesce(c.welcome, '{}'::jsonb);
  app := coalesce(nullif(btrim((select value from public.app_settings where key = 'app_url')), ''), '');
  app := btrim(app, '"');
  begin st := (select value::jsonb from public.app_settings where key = 'store_links'); exception when others then st := '{}'::jsonb; end;
  store := concat_ws(E'\n', case when coalesce(st->>'ios','') <> '' then 'iPhone: ' || (st->>'ios') end, case when coalesce(st->>'android','') <> '' then 'Android: ' || (st->>'android') end);
  biz := coalesce(nullif(btrim((select value::jsonb->>'main' from public.app_settings where key = 'acc_names')), ''), 'us');
  -- what opens on which day: lessons with a day, in order; the rest are open straight away
  select string_agg(line, E'\n' order by d, s) into sched from (
    select coalesce(l.open_day, 1) d, min(l.sort) s,
      'Day ' || coalesce(l.open_day, 1) || ': ' || string_agg(l.title, ', ' order by l.sort) line
    from public.course_lessons l where l.course_id = c.id group by coalesce(l.open_day, 1)) x;
  login := case when cu.user_id is not null then 'Sign in with ' || cu.email || ' and your password. Forgot it? Tap Forgot password on the sign in page.'
    else 'Tap Create account and use this email: ' || cu.email || '. Use the same email, so your course is there when you sign in.' end;
  first := split_part(btrim(coalesce(cu.name, '')), ' ', 1); if first = '' then first := 'there'; end if;
  subj := coalesce(nullif(btrim(w->>'subject'), ''), 'Your course is ready: {course}');
  body := coalesce(nullif(btrim(w->>'body'), ''),
    E'Hi {first},\n\nThank you, {course} is yours. Here is how to start.\n\n1. GET THE APP\n{app}\n{store}\n\n2. SIGN IN\n{login}\n\n3. OPEN YOUR COURSE\nIn the app, tap Learn and open {course}. Day 1 is the day you got it. New lessons open as the days go by, so you build up step by step:\n{schedule}\n\nWatch each lesson, practise it, then move on. Take your time and come back to the lessons as often as you like.\n\nAny questions, just reply to this email.\n\n{business}');
  subj := replace(replace(subj, '{course}', c.title), '{first}', first);
  body := replace(replace(replace(replace(replace(replace(replace(replace(replace(body,
    '{first}', first), '{course}', c.title), '{app}', coalesce(nullif(app, ''), 'Open our app') || case when app <> '' then '#c_learn' else '' end),
    '{store}', coalesce(store, '')), '{login}', login), '{schedule}', coalesce(sched, 'Every lesson is open now.')), '{business}', biz), '{email}', coalesce(cu.email, '')),
    '{link}', coalesce(nullif(app, ''), '') || case when app <> '' then '#c_learn' else '' end);
  body := regexp_replace(body, E'\n{3,}', E'\n\n', 'g');
  return jsonb_build_object('subject', subj, 'body', body, 'to', lower(cu.email), 'name', cu.name);
end $$;

create or replace function private.course_welcome_queue() returns trigger
language plpgsql security definer set search_path to '' as $$
declare c public.courses%rowtype; t jsonb; tag text := 'course_welcome:' || new.course_id;
begin
  if not private.feature('course_welcome', true) then return new; end if;
  select * into c from public.courses where id = new.course_id;
  if c.id is null or coalesce((c.welcome->>'on')::boolean, true) = false then return new; end if;
  if exists (select 1 from public.sent_emails where customer_id = new.customer_id and campaign = tag) then return new; end if;
  t := private.course_welcome_text(new.course_id, new.customer_id);
  if t is null or coalesce(t->>'to','') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return new; end if;
  insert into public.sent_emails (customer_id, to_email, to_name, subject, body, status, campaign, send_after)
  values (new.customer_id, t->>'to', t->>'name', t->>'subject', t->>'body', 'queued', tag, now());
  return new;
end $$;

drop trigger if exists course_access_welcome on public.course_access;
create trigger course_access_welcome after insert on public.course_access for each row execute function private.course_welcome_queue();

-- managers: the wording for one course, and a preview with their own details filled in
create or replace function public.course_welcome_set(p_course uuid, p jsonb, p_app text default null) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  update public.courses set welcome = jsonb_build_object('on', coalesce((p->>'on')::boolean, true), 'subject', left(coalesce(p->>'subject',''),200), 'body', left(coalesce(p->>'body',''),8000)) where id = p_course;
  if coalesce(p_app,'') ~ '^https://[^\s]+$' then
    insert into public.app_settings (key, value) values ('app_url', p_app) on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
end $$;

create or replace function public.course_welcome_get(p_course uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return (select coalesce(welcome, '{}'::jsonb) from public.courses where id = p_course);
end $$;

create or replace function public.course_welcome_preview(p_course uuid, p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return private.course_welcome_text(p_course, p_customer);
end $$;

-- send it again (or for the first time) to someone who already has the course
create or replace function public.course_welcome_send(p_course uuid, p_customer uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare t jsonb;
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  t := private.course_welcome_text(p_course, p_customer);
  if t is null or coalesce(t->>'to','') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'They have no email address.'; end if;
  insert into public.sent_emails (customer_id, to_email, to_name, subject, body, status, campaign, send_after)
  values (p_customer, t->>'to', t->>'name', t->>'subject', t->>'body', 'queued', 'course_welcome:' || p_course, now());
end $$;

revoke all on function private.course_welcome_text(uuid, uuid) from public, anon, authenticated;
revoke all on function public.course_welcome_get(uuid), public.course_welcome_set(uuid, jsonb, text), public.course_welcome_preview(uuid, uuid), public.course_welcome_send(uuid, uuid) from public, anon;
grant execute on function public.course_welcome_get(uuid), public.course_welcome_set(uuid, jsonb, text), public.course_welcome_preview(uuid, uuid), public.course_welcome_send(uuid, uuid) to authenticated;
