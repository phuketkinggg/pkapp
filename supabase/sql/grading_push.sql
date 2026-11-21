-- Grading: when a customer is given a new level, their phone gets a notification, and so do their parents' phones (kids mode).
-- Part of the grading feature; works for adults too.

create or replace function private.grade_push(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare g public.customer_grades; who text; lvl text; lv jsonb;
begin
  select * into g from public.customer_grades where id = p_id;
  if g.id is null then return null; end if;
  select name into who from public.customers where id = g.customer_id;
  lv := (select case when a.value ~ '^\s*\{' then a.value::jsonb->'levels' end from public.app_settings a where a.key = 'grading');
  lvl := coalesce(lv->g.level->>'name', 'level ' || (g.level + 1));
  return jsonb_build_object('title', 'New grading level',
    'body', left(split_part(coalesce(who, 'Your child'), ' ', 1) || ' is now ' || lvl || '. Well done!', 180),
    'tag', 'grade-' || g.id, 'url', '#c_home',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'p256dh', x.p256dh, 'auth', x.auth))
      from public.push_subs x where x.off_at is null and x.staff_id is null and x.user_id in (
        select c.user_id from public.customers c where c.id = g.customer_id and c.user_id is not null
        union select p.user_id from public.kid_guardians k join public.customers p on p.id = k.guardian_id where k.kid_id = g.customer_id and p.user_id is not null and private.kids_on())), '[]'::jsonb));
end $f$;

create or replace function private.grade_push_send() returns trigger language plpgsql security definer set search_path = '' as $f$
declare tok text; base text;
begin
  if not private.feature('grading', false) then return null; end if;
  if not exists (select 1 from public.push_subs x where x.off_at is null and x.staff_id is null and x.user_id in (
      select c.user_id from public.customers c where c.id = new.customer_id
      union select p.user_id from public.kid_guardians k join public.customers p on p.id = k.guardian_id where k.kid_id = new.customer_id)) then return null; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  select value into base from private.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'push', 'kind', 'grade', 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;

do $p$
declare d text; n text;
begin
  if to_regclass('public.customer_grades') is null or to_regclass('public.kid_guardians') is null then raise notice 'grading_push: needs kids_grading and kids_mode first, skipped'; return; end if;
  drop trigger if exists customer_grades_push on public.customer_grades;
  create trigger customer_grades_push after insert on public.customer_grades for each row execute function private.grade_push_send();
  d := pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure);
  if position('private.grade_push(' in d) > 0 then return; end if;
  n := replace(d, '  if p_kind <> ''arrival'' then return null; end if;', '  if p_kind = ''grade'' then return private.grade_push(p_id); end if;
  if p_kind <> ''arrival'' then return null; end if;');
  if n = d then raise notice 'grading_push: push_targets is different, skipped'; return; end if;
  execute n;
end $p$;
