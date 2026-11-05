-- Package welcome email (feature pkg_welcome): when someone buys a training package on the website and it is paid,
-- they get one welcome email by themselves: their package and start date, class times from the timetable, how to get the app
-- and sign in, and where to find the gym. The wording is a setting (app_settings pkg_welcome: on, subject, body) with {words} filled in.
-- The email goes in the email queue (sent_emails), sent within 10 minutes by the outreach email job.

create or replace function private.pkg_welcome_text(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare o public.web_pkg_orders%rowtype; cu public.customers%rowtype; w jsonb; we jsonb; app text; st jsonb; store text; biz text; first text; login text;
  cls text; wa text; subj text; body text; priv boolean;
begin
  select * into o from public.web_pkg_orders where id = p_order; if o.id is null or o.package_id is null then return null; end if;
  select * into cu from public.customers where id = o.customer_id;
  begin w := (select value::jsonb from public.app_settings where key = 'pkg_welcome'); exception when others then w := null; end; w := coalesce(w, '{}'::jsonb);
  begin we := (select value::jsonb from public.app_settings where key = 'welcome_email'); exception when others then we := null; end; we := coalesce(we, '{}'::jsonb);
  begin st := (select value::jsonb from public.app_settings where key = 'store_links'); exception when others then st := null; end; st := coalesce(st, '{}'::jsonb);
  app := btrim(coalesce((select value from public.app_settings where key = 'app_url'), ''), '" ');
  store := concat_ws(E'\n', case when coalesce(st->>'ios','') <> '' then 'iPhone: ' || (st->>'ios') end, case when coalesce(st->>'android','') <> '' then 'Android: ' || (st->>'android') end);
  biz := coalesce(nullif(btrim((select value::jsonb->>'main' from public.app_settings where key = 'acc_names')), ''), 'us');
  wa := regexp_replace(coalesce(we->>'whatsapp', ''), '[^0-9]', '', 'g');
  -- class times, Monday to Friday, from the timetable: each start time with the name of the class
  select string_agg(t || ' ' || n, E'\n' order by t) into cls from (
    select to_char(c.start_time, 'HH24:MI') t, min(split_part(c.title, ',', 1)) n from public.classes c
    where not coalesce(c.no_checkin, false) and c.day between 1 and 5 group by 1) x;
  -- a privates only package: the coach confirms the time, group class times come after as an extra
  select coalesce(k.covers = array['Privates']::text[], false) into priv from public.packages k where k.id = o.package_id;
  if coalesce(priv, false) then
    cls := 'Privates are one to one, at a time that suits you. Your coach will message you to confirm your session time.' || coalesce(E'\n\nWant to join a group class too? Group classes, Monday to Friday:\n' || cls, '');
  else cls := coalesce('Group classes, Monday to Friday:' || E'\n' || cls, 'See the timetable in the app.'); end if;
  first := split_part(btrim(coalesce(cu.name, o.name, '')), ' ', 1); if first = '' then first := 'there'; end if;
  login := case when cu.user_id is not null then 'Sign in with ' || coalesce(cu.email, o.email) || ' and your password. Forgot it? Tap Forgot password on the sign in page.'
    else 'Tap Create account and use this email: ' || coalesce(cu.email, o.email) || '. Use the same email, so your package is there when you sign in.' end;
  subj := coalesce(nullif(btrim(w->>'subject'), ''), 'Welcome to {business}: your {package}');
  body := coalesce(nullif(btrim(w->>'body'), ''),
    E'Hi {first},\n\nThank you for booking {package}. We cannot wait to train with you. Here is everything you need.\n\nYOUR PACKAGE\n{package}{start}\n\nYOUR TRAINING\n{classes}\nCome 10 to 15 minutes early for your first session, so we can say hello and show you around.\n\nTHE APP\nSee the timetable, your package and check in with the app:\n{app}\n{store}\n{login}\n\nWHAT TO BRING\nWater, a towel and comfortable training clothes. Hand wraps and gloves if you have them; if not, ask at the front desk.\n\nWHERE WE ARE\nMessage us on WhatsApp and we will send you the location pin: {whatsapp}\n\nSee you soon,\n{business}');
  subj := replace(replace(subj, '{business}', biz), '{package}', o.package_name);
  body := replace(replace(replace(replace(replace(replace(replace(replace(replace(body,
    '{first}', first), '{package}', o.package_name), '{start}', case when o.start_on is not null then ', starting ' || to_char(o.start_on, 'FMDay FMDD Mon YYYY') else '' end),
    '{classes}', coalesce(cls, 'See the timetable in the app.')), '{app}', coalesce(nullif(app, ''), 'Open our app')), '{store}', coalesce(store, '')),
    '{login}', login), '{whatsapp}', case when wa <> '' then 'https://wa.me/' || wa else 'reply to this email' end), '{business}', biz);
  body := regexp_replace(body, E'\n{3,}', E'\n\n', 'g');
  return jsonb_build_object('subject', subj, 'body', body, 'to', lower(coalesce(cu.email, o.email)), 'name', coalesce(cu.name, o.name), 'customer_id', o.customer_id);
end $$;

create or replace function private.pkg_welcome_queue() returns trigger
language plpgsql security definer set search_path to '' as $$
declare t jsonb; w jsonb; tag text := 'pkg_welcome:' || new.id;
begin
  if new.purchase_id is null or new.package_id is null or (tg_op = 'UPDATE' and old.purchase_id is not null) then return new; end if;
  if not private.feature('pkg_welcome', true) then return new; end if;
  begin w := (select value::jsonb from public.app_settings where key = 'pkg_welcome'); exception when others then w := null; end;
  if coalesce((w->>'on')::boolean, true) = false then return new; end if;
  if exists (select 1 from public.sent_emails where campaign = tag) then return new; end if;
  t := private.pkg_welcome_text(new.id);
  if t is null or coalesce(t->>'to','') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return new; end if;
  insert into public.sent_emails (customer_id, to_email, to_name, subject, body, status, campaign, send_after)
  values ((t->>'customer_id')::uuid, t->>'to', t->>'name', t->>'subject', t->>'body', 'queued', tag, now());
  return new;
end $$;

drop trigger if exists web_pkg_orders_welcome on public.web_pkg_orders;
create trigger web_pkg_orders_welcome after insert or update of purchase_id on public.web_pkg_orders for each row execute function private.pkg_welcome_queue();

revoke all on function private.pkg_welcome_text(uuid) from public, anon, authenticated;
