-- Website sign up forms (feature site_signups): a "Sign up form" section on any website page, for pre-registrations, waiting lists and interest.
-- Visitors leave their name, email, phone and the answers to the page's own questions. Managers see them in Website pages, Sign ups, and get a phone notice.

create table if not exists public.site_signups (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  page text,
  list text not null,
  name text not null,
  email text,
  phone text,
  answers jsonb not null default '[]'::jsonb,
  done boolean not null default false,
  done_by uuid
);
alter table public.site_signups enable row level security;
create index if not exists site_signups_at on public.site_signups(created_at desc);

-- a visitor sends the form (no sign in). p: {page, list, name, email, phone, answers:[{q, a}]}
create or replace function public.site_signup(p jsonb) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare n text := btrim(coalesce(p->>'name', '')); e text := lower(btrim(coalesce(p->>'email', ''))); ph text := btrim(coalesce(p->>'phone', ''));
  l text := left(btrim(coalesce(p->>'list', '')), 120); pg text := left(btrim(coalesce(p->>'page', '')), 80); a jsonb := '[]'::jsonb; x jsonb; nid uuid;
begin
  if not private.feature('site_signups', true) then raise exception 'Sign ups are closed.'; end if;
  if n = '' or char_length(n) > 120 then raise exception 'Write your name.'; end if;
  if e = '' and ph = '' then raise exception 'Give your email or phone, so we can reach you.'; end if;
  if e <> '' and (char_length(e) > 160 or e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'Check your email.'; end if;
  if char_length(ph) > 40 then raise exception 'Check your phone number.'; end if;
  if l = '' then l := 'Sign ups'; end if;
  if jsonb_typeof(p->'answers') = 'array' then
    for x in select * from jsonb_array_elements(p->'answers') limit 12 loop
      a := a || jsonb_build_array(jsonb_build_object('q', left(coalesce(x->>'q', ''), 160), 'a', left(coalesce(x->>'a', ''), 600)));
    end loop;
  end if;
  -- the same person sends again: update their answers instead of a second line
  select id into nid from public.site_signups where list = l and created_at > now() - interval '30 days'
    and ((e <> '' and email = e) or (ph <> '' and regexp_replace(phone, '\D', '', 'g') = regexp_replace(ph, '\D', '', 'g') and ph ~ '\d{6}')) order by created_at desc limit 1;
  if nid is not null then
    update public.site_signups set name = n, email = nullif(e, ''), phone = nullif(ph, ''), answers = a, page = pg where id = nid;
    return jsonb_build_object('ok', true, 'again', true);
  end if;
  if (select count(*) from public.site_signups where created_at > now() - interval '1 day') >= 300 then raise exception 'Too many sign ups today. Please message us instead.'; end if;
  insert into public.site_signups (page, list, name, email, phone, answers) values (pg, l, n, nullif(e, ''), nullif(ph, ''), a);
  return jsonb_build_object('ok', true);
end $f$;
revoke all on function public.site_signup(jsonb) from public;
grant execute on function public.site_signup(jsonb) to anon, authenticated;

-- managers: the sign ups, newest first
create or replace function public.site_signups_list() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if not coalesce(private.staff_role() in ('manager','front_desk'), false) then raise exception 'Only a manager or the front desk can see this.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'at', s.created_at, 'page', s.page, 'list', s.list, 'name', s.name, 'email', s.email, 'phone', s.phone, 'answers', s.answers, 'done', s.done) order by s.created_at desc), '[]'::jsonb)
    from (select * from public.site_signups order by created_at desc limit 1000) s);
end $f$;

create or replace function public.site_signup_set(p_id uuid, p_done boolean default null, p_remove boolean default false) returns void language plpgsql security definer set search_path = '' as $f$
begin
  if not coalesce(private.staff_role() in ('manager','front_desk'), false) then raise exception 'Only a manager or the front desk can do this.'; end if;
  if p_remove then
    if private.staff_role() <> 'manager' then raise exception 'Only a manager can remove sign ups.'; end if;
    delete from public.site_signups where id = p_id; return;
  end if;
  update public.site_signups set done = coalesce(p_done, not done), done_by = private.my_staff_id() where id = p_id;
end $f$;
revoke all on function public.site_signups_list(), public.site_signup_set(uuid, boolean, boolean) from public, anon;
grant execute on function public.site_signups_list(), public.site_signup_set(uuid, boolean, boolean) to authenticated;

-- a phone notice to managers and the front desk for each new sign up
create or replace function private.signup_push(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare s public.site_signups;
begin
  select * into s from public.site_signups where id = p_id; if s.id is null then return null; end if;
  return jsonb_build_object('title', 'New sign up: ' || s.list,
    'body', left(s.name || coalesce(', ' || s.phone, '') || coalesce(', ' || s.email, '') || coalesce('. ' || (select string_agg(x->>'q' || ': ' || (x->>'a'), ', ') from jsonb_array_elements(s.answers) x where coalesce(x->>'a', '') <> ''), ''), 180),
    'tag', 'signup-' || s.id, 'url', '#webpages',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'p256dh', x.p256dh, 'auth', x.auth))
      from public.push_subs x join public.staff st on st.id = x.staff_id where x.off_at is null and st.active and st.role in ('manager','front_desk')), '[]'::jsonb));
end $f$;

create or replace function private.signup_push_send() returns trigger language plpgsql security definer set search_path = '' as $f$
declare tok text; base text;
begin
  if not exists (select 1 from public.push_subs x join public.staff st on st.id = x.staff_id where x.off_at is null and st.active and st.role in ('manager','front_desk')) then return null; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  select value into base from private.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'push', 'kind', 'signup', 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;

do $p$
declare d text; n text;
begin
  drop trigger if exists site_signups_push on public.site_signups;
  create trigger site_signups_push after insert on public.site_signups for each row execute function private.signup_push_send();
  if to_regprocedure('public.push_targets(text,uuid)') is null then return; end if;
  d := pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure);
  if position('private.signup_push(' in d) > 0 then return; end if;
  n := replace(d, '  if p_kind <> ''arrival'' then return null; end if;', '  if p_kind = ''signup'' then return private.signup_push(p_id); end if;
  if p_kind <> ''arrival'' then return null; end if;');
  if n = d then raise notice 'site_signups: push_targets is different, skipped'; return; end if;
  execute n;
end $p$;

notify pgrst, 'reload schema';
