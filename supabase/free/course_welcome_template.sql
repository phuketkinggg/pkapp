delete from mf.template where name like 'course_welcome:%';
insert into mf.template (ord, phase, kind, name, sql) values (301001, 3, 'patch', 'course_welcome:301001', $TPL$alter table __P__.courses add column if not exists welcome jsonb;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401501, 4, 'patch', 'course_welcome:401501', $TPL$create or replace function __Q__.course_welcome_text(p_course uuid, p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare c __P__.courses%rowtype; cu __P__.customers%rowtype; w jsonb; app text; st jsonb; sched text; login text; biz text; subj text; body text; first text; store text;
begin
  select * into c from __P__.courses where id = p_course; select * into cu from __P__.customers where id = p_customer;
  if c.id is null or cu.id is null then return null; end if;
  w := coalesce(c.welcome, '{}'::jsonb);
  app := coalesce(nullif(btrim((select value from __P__.app_settings where key = 'app_url')), ''), '');
  app := btrim(app, '"');
  begin st := (select value::jsonb from __P__.app_settings where key = 'store_links'); exception when others then st := '{}'::jsonb; end;
  store := concat_ws(E'\n', case when coalesce(st->>'ios','') <> '' then 'iPhone: ' || (st->>'ios') end, case when coalesce(st->>'android','') <> '' then 'Android: ' || (st->>'android') end);
  biz := coalesce(nullif(btrim((select value::jsonb->>'main' from __P__.app_settings where key = 'acc_names')), ''), 'us');
  -- what opens on which day: lessons with a day, in order; the rest are open straight away
  select string_agg(line, E'\n' order by d, s) into sched from (
    select coalesce(l.open_day, 1) d, min(l.sort) s,
      'Day ' || coalesce(l.open_day, 1) || ': ' || string_agg(l.title, ', ' order by l.sort) line
    from __P__.course_lessons l where l.course_id = c.id group by coalesce(l.open_day, 1)) x;
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
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401502, 4, 'patch', 'course_welcome:401502', $TPL$create or replace function __Q__.course_welcome_queue() returns trigger
language plpgsql security definer set search_path to '' as $$
declare c __P__.courses%rowtype; t jsonb; tag text := 'course_welcome:' || new.course_id;
begin
  if not __Q__.feature('course_welcome', true) then return new; end if;
  select * into c from __P__.courses where id = new.course_id;
  if c.id is null or coalesce((c.welcome->>'on')::boolean, true) = false then return new; end if;
  if exists (select 1 from __P__.sent_emails where customer_id = new.customer_id and campaign = tag) then return new; end if;
  t := __Q__.course_welcome_text(new.course_id, new.customer_id);
  if t is null or coalesce(t->>'to','') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return new; end if;
  insert into __P__.sent_emails (customer_id, to_email, to_name, subject, body, status, campaign, send_after)
  values (new.customer_id, t->>'to', t->>'name', t->>'subject', t->>'body', 'queued', tag, now());
  return new;
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900401, 9, 'patch', 'course_welcome:900401', $TPL$drop trigger if exists course_access_welcome on __P__.course_access;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (900402, 9, 'patch', 'course_welcome:900402', $TPL$create trigger course_access_welcome after insert on __P__.course_access for each row execute function __Q__.course_welcome_queue();$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401503, 4, 'patch', 'course_welcome:401503', $TPL$create or replace function __P__.course_welcome_set(p_course uuid, p jsonb, p_app text default null) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change this.'; end if;
  update __P__.courses set welcome = jsonb_build_object('on', coalesce((p->>'on')::boolean, true), 'subject', left(coalesce(p->>'subject',''),200), 'body', left(coalesce(p->>'body',''),8000)) where id = p_course;
  if coalesce(p_app,'') ~ '^https://[^\s]+$' then
    insert into __P__.app_settings (key, value) values ('app_url', p_app) on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401504, 4, 'patch', 'course_welcome:401504', $TPL$create or replace function __P__.course_welcome_get(p_course uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return (select coalesce(welcome, '{}'::jsonb) from __P__.courses where id = p_course);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401505, 4, 'patch', 'course_welcome:401505', $TPL$create or replace function __P__.course_welcome_preview(p_course uuid, p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can see this.'; end if;
  return __Q__.course_welcome_text(p_course, p_customer);
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401506, 4, 'patch', 'course_welcome:401506', $TPL$create or replace function __P__.course_welcome_send(p_course uuid, p_customer uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare t jsonb;
begin
  if coalesce(__Q__.staff_role(),'') <> 'manager' then raise exception 'Only a manager can do this.'; end if;
  t := __Q__.course_welcome_text(p_course, p_customer);
  if t is null or coalesce(t->>'to','') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'They have no email address.'; end if;
  insert into __P__.sent_emails (customer_id, to_email, to_name, subject, body, status, campaign, send_after)
  values (p_customer, t->>'to', t->>'name', t->>'subject', t->>'body', 'queued', 'course_welcome:' || p_course, now());
end $$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1195301, 11, 'patch', 'course_welcome:1195301', $TPL$revoke all on function __Q__.course_welcome_text(uuid, uuid) from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1195302, 11, 'patch', 'course_welcome:1195302', $TPL$revoke all on function __P__.course_welcome_get(uuid), __P__.course_welcome_set(uuid, jsonb, text), __P__.course_welcome_preview(uuid, uuid), __P__.course_welcome_send(uuid, uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1195303, 11, 'patch', 'course_welcome:1195303', $TPL$grant execute on function __P__.course_welcome_get(uuid), __P__.course_welcome_set(uuid, jsonb, text), __P__.course_welcome_preview(uuid, uuid), __P__.course_welcome_send(uuid, uuid) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'course_welcome:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
