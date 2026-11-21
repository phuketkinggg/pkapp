delete from mf.template where name like 'site_signups:%';
insert into mf.template (ord, phase, kind, name, sql) values (304301, 3, 'patch', 'site_signups:304301', $TPL$create table if not exists __P__.site_signups (
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
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (304302, 3, 'patch', 'site_signups:304302', $TPL$alter table __P__.site_signups enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002901, 10, 'patch', 'site_signups:1002901', $TPL$create index if not exists site_signups_at on __P__.site_signups(created_at desc);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404301, 4, 'patch', 'site_signups:404301', $TPL$create or replace function __P__.site_signup(p jsonb) returns jsonb language plpgsql security definer set search_path = '' as $f$
declare n text := btrim(coalesce(p->>'name', '')); e text := lower(btrim(coalesce(p->>'email', ''))); ph text := btrim(coalesce(p->>'phone', ''));
  l text := left(btrim(coalesce(p->>'list', '')), 120); pg text := left(btrim(coalesce(p->>'page', '')), 80); a jsonb := '[]'::jsonb; x jsonb; nid uuid;
begin
  if not __Q__.feature('site_signups', true) then raise exception 'Sign ups are closed.'; end if;
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
  select id into nid from __P__.site_signups where list = l and created_at > now() - interval '30 days'
    and ((e <> '' and email = e) or (ph <> '' and regexp_replace(phone, '\D', '', 'g') = regexp_replace(ph, '\D', '', 'g') and ph ~ '\d{6}')) order by created_at desc limit 1;
  if nid is not null then
    update __P__.site_signups set name = n, email = nullif(e, ''), phone = nullif(ph, ''), answers = a, page = pg where id = nid;
    return jsonb_build_object('ok', true, 'again', true);
  end if;
  if (select count(*) from __P__.site_signups where created_at > now() - interval '1 day') >= 300 then raise exception 'Too many sign ups today. Please message us instead.'; end if;
  insert into __P__.site_signups (page, list, name, email, phone, answers) values (pg, l, n, nullif(e, ''), nullif(ph, ''), a);
  return jsonb_build_object('ok', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198401, 11, 'patch', 'site_signups:1198401', $TPL$revoke all on function __P__.site_signup(jsonb) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198402, 11, 'patch', 'site_signups:1198402', $TPL$grant execute on function __P__.site_signup(jsonb) to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404302, 4, 'patch', 'site_signups:404302', $TPL$create or replace function __P__.site_signups_list() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if not coalesce(__Q__.staff_role() in ('manager','front_desk'), false) then raise exception 'Only a manager or the front desk can see this.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'at', s.created_at, 'page', s.page, 'list', s.list, 'name', s.name, 'email', s.email, 'phone', s.phone, 'answers', s.answers, 'done', s.done) order by s.created_at desc), '[]'::jsonb)
    from (select * from __P__.site_signups order by created_at desc limit 1000) s);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404303, 4, 'patch', 'site_signups:404303', $TPL$create or replace function __P__.site_signup_set(p_id uuid, p_done boolean default null, p_remove boolean default false) returns void language plpgsql security definer set search_path = '' as $f$
begin
  if not coalesce(__Q__.staff_role() in ('manager','front_desk'), false) then raise exception 'Only a manager or the front desk can do this.'; end if;
  if p_remove then
    if __Q__.staff_role() <> 'manager' then raise exception 'Only a manager can remove sign ups.'; end if;
    delete from __P__.site_signups where id = p_id; return;
  end if;
  update __P__.site_signups set done = coalesce(p_done, not done), done_by = __Q__.my_staff_id() where id = p_id;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198403, 11, 'patch', 'site_signups:1198403', $TPL$revoke all on function __P__.site_signups_list(), __P__.site_signup_set(uuid, boolean, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198404, 11, 'patch', 'site_signups:1198404', $TPL$grant execute on function __P__.site_signups_list(), __P__.site_signup_set(uuid, boolean, boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404304, 4, 'patch', 'site_signups:404304', $TPL$create or replace function __Q__.signup_push(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare s __P__.site_signups;
begin
  select * into s from __P__.site_signups where id = p_id; if s.id is null then return null; end if;
  return jsonb_build_object('title', 'New sign up: ' || s.list,
    'body', left(s.name || coalesce(', ' || s.phone, '') || coalesce(', ' || s.email, '') || coalesce('. ' || (select string_agg(x->>'q' || ': ' || (x->>'a'), ', ') from jsonb_array_elements(s.answers) x where coalesce(x->>'a', '') <> ''), ''), 180),
    'tag', 'signup-' || s.id, 'url', '#webpages',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'p256dh', x.p256dh, 'auth', x.auth))
      from __P__.push_subs x join __P__.staff st on st.id = x.staff_id where x.off_at is null and st.active and st.role in ('manager','front_desk')), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404305, 4, 'patch', 'site_signups:404305', $TPL$create or replace function __Q__.signup_push_send() returns trigger language plpgsql security definer set search_path = '' as $f$
declare tok text; base text;
begin
  if not exists (select 1 from __P__.push_subs x join __P__.staff st on st.id = x.staff_id where x.off_at is null and st.active and st.role in ('manager','front_desk')) then return null; end if;
  select value into tok from __Q__.sync_settings where key = 'sync_token';
  select value into base from __Q__.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'push', 'kind', 'signup', 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (902501, 9, 'patch', 'site_signups:902501', $TPL$do $p$
declare d text; n text;
begin
  drop trigger if exists site_signups_push on __P__.site_signups;
  create trigger site_signups_push after insert on __P__.site_signups for each row execute function __Q__.signup_push_send();
  if to_regprocedure('__P__.push_targets(text,uuid)') is null then return; end if;
  d := pg_get_functiondef('__P__.push_targets(text,uuid)'::regprocedure);
  if position('__Q__.signup_push(' in d) > 0 then return; end if;
  n := replace(d, '  if p_kind <> ''arrival'' then return null; end if;', '  if p_kind = ''signup'' then return __Q__.signup_push(p_id); end if;
  if p_kind <> ''arrival'' then return null; end if;');
  if n = d then raise notice 'site_signups: push_targets is different, skipped'; return; end if;
  execute n;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'site_signups:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
