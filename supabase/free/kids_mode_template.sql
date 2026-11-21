delete from mf.template where name like 'kids_mode:%';
insert into mf.template (ord, phase, kind, name, sql) values (304101, 3, 'patch', 'kids_mode:304101', $TPL$create table if not exists __P__.kid_guardians (
  kid_id uuid not null references __P__.customers(id) on delete cascade,
  guardian_id uuid not null references __P__.customers(id) on delete cascade,
  added_by uuid,
  added_at timestamptz not null default now(),
  primary key (kid_id, guardian_id),
  check (kid_id <> guardian_id)
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (304102, 3, 'patch', 'kids_mode:304102', $TPL$alter table __P__.kid_guardians enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002701, 10, 'patch', 'kids_mode:1002701', $TPL$create index if not exists kid_guardians_guardian on __P__.kid_guardians(guardian_id);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (304103, 3, 'patch', 'kids_mode:304103', $TPL$create table if not exists __Q__.kid_acting (
  user_id uuid primary key,
  kid_id uuid not null,
  at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (304104, 3, 'patch', 'kids_mode:304104', $TPL$create table if not exists __Q__.kid_codes (
  code text primary key,
  kid_id uuid not null,
  made_by uuid,
  until timestamptz not null default now() + interval '7 days'
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404101, 4, 'patch', 'kids_mode:404101', $TPL$create or replace function __Q__.kids_on() returns boolean language sql stable security definer set search_path = '' as $f$
  select __Q__.feature('kids_mode', false)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404102, 4, 'patch', 'kids_mode:404102', $TPL$create or replace function __Q__.own_customer_id() returns uuid language sql stable security definer set search_path = '' as $f$
  select c.id from __P__.customers c where c.user_id = (select auth.uid()) order by c.created_at limit 1
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404103, 4, 'patch', 'kids_mode:404103', $TPL$create or replace function __Q__.is_kid(c uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select c is not null and __Q__.kids_on() and exists (select 1 from __P__.kid_guardians g where g.kid_id = c)
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404104, 4, 'patch', 'kids_mode:404104', $TPL$create or replace function __Q__.chat_customer(c uuid) returns uuid language sql stable security definer set search_path = '' as $f$
  select case when __Q__.is_kid(c) then coalesce((select g.guardian_id from __P__.kid_guardians g where g.kid_id = c order by g.added_at limit 1), c) else c end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404105, 4, 'patch', 'kids_mode:404105', $TPL$create or replace function __Q__.family(c uuid) returns uuid[] language sql stable security definer set search_path = '' as $f$
  select array[c] || case when __Q__.kids_on() then coalesce((select array_agg(g.kid_id) from __P__.kid_guardians g where g.guardian_id = c), '{}'::uuid[]) else '{}'::uuid[] end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404106, 4, 'patch', 'kids_mode:404106', $TPL$create or replace function __Q__.chat_me() returns uuid language sql stable security definer set search_path = '' as $f$
  select case when __Q__.is_kid(x.id) then null else x.id end from (select __Q__.own_customer_id() id) x
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404107, 4, 'patch', 'kids_mode:404107', $TPL$create or replace function __Q__.customer_id() returns uuid language sql stable security definer set search_path = '' as $f$
  select coalesce(
    (select a.kid_id from __Q__.kid_acting a
      where a.user_id = (select auth.uid()) and __Q__.kids_on()
        and exists (select 1 from __P__.kid_guardians g where g.kid_id = a.kid_id and g.guardian_id = __Q__.own_customer_id())),
    __Q__.own_customer_id())
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404108, 4, 'patch', 'kids_mode:404108', $TPL$create or replace function __P__.kids_mine() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare me uuid := __Q__.own_customer_id();
begin
  if me is null or not __Q__.kids_on() then return jsonb_build_object('on', __Q__.kids_on(), 'kids', '[]'::jsonb, 'acting', null, 'me_kid', false); end if;
  return jsonb_build_object('on', true, 'me_kid', __Q__.is_kid(me), 'me', me,
    'acting', (select a.kid_id from __Q__.kid_acting a where a.user_id = auth.uid() and exists (select 1 from __P__.kid_guardians g where g.kid_id = a.kid_id and g.guardian_id = me)),
    'kids', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name,
        'parents', (select coalesce(jsonb_agg(p.name order by g2.added_at), '[]'::jsonb) from __P__.kid_guardians g2 join __P__.customers p on p.id = g2.guardian_id where g2.kid_id = k.id)) order by k.name), '[]'::jsonb)
      from __P__.kid_guardians g join __P__.customers k on k.id = g.kid_id where g.guardian_id = me));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404109, 4, 'patch', 'kids_mode:404109', $TPL$create or replace function __P__.kid_add(p_name text) returns uuid language plpgsql security definer set search_path = '' as $f$
declare me uuid := __Q__.own_customer_id(); n text := btrim(coalesce(p_name, '')); kid uuid;
begin
  if not __Q__.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null then raise exception 'Sign in first.'; end if;
  if __Q__.is_kid(me) then raise exception 'Ask your parent to do this.'; end if;
  if n = '' or char_length(n) > 80 then raise exception 'Write your child''s name.'; end if;
  if (select count(*) from __P__.kid_guardians where guardian_id = me) >= 8 then raise exception 'You can add up to 8 children.'; end if;
  insert into __P__.customers (name, lead_source, tags) values (n, 'kids', array['kid']) returning id into kid;
  insert into __P__.kid_guardians (kid_id, guardian_id, added_by) values (kid, me, auth.uid());
  return kid;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404110, 4, 'patch', 'kids_mode:404110', $TPL$create or replace function __P__.kid_open(p_kid uuid) returns void language plpgsql security definer set search_path = '' as $f$
declare me uuid := __Q__.own_customer_id();
begin
  if p_kid is null then delete from __Q__.kid_acting where user_id = auth.uid(); return; end if;
  if not __Q__.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null or not exists (select 1 from __P__.kid_guardians g where g.kid_id = p_kid and g.guardian_id = me) then raise exception 'That child is not linked to you.'; end if;
  insert into __Q__.kid_acting (user_id, kid_id) values (auth.uid(), p_kid) on conflict (user_id) do update set kid_id = excluded.kid_id, at = now();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404111, 4, 'patch', 'kids_mode:404111', $TPL$create or replace function __P__.kid_share(p_kid uuid) returns text language plpgsql security definer set search_path = '' as $f$
declare me uuid := __Q__.own_customer_id(); c text;
begin
  if not __Q__.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null or not exists (select 1 from __P__.kid_guardians g where g.kid_id = p_kid and g.guardian_id = me) then raise exception 'That child is not linked to you.'; end if;
  delete from __Q__.kid_codes where until < now();
  loop
    c := upper(substr(translate(encode(extensions.gen_random_bytes(8), 'base64'), '+/=01OIl', ''), 1, 6));
    exit when char_length(c) = 6 and not exists (select 1 from __Q__.kid_codes where code = c);
  end loop;
  insert into __Q__.kid_codes (code, kid_id, made_by) values (c, p_kid, me);
  return c;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404112, 4, 'patch', 'kids_mode:404112', $TPL$create or replace function __P__.kid_join(p_code text) returns text language plpgsql security definer set search_path = '' as $f$
declare me uuid := __Q__.own_customer_id(); k uuid;
begin
  if not __Q__.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null then raise exception 'Sign in first.'; end if;
  if __Q__.is_kid(me) then raise exception 'Ask your parent to do this.'; end if;
  select kid_id into k from __Q__.kid_codes where code = upper(btrim(coalesce(p_code, ''))) and until > now();
  if k is null then raise exception 'That code is wrong or too old. Ask for a new one.'; end if;
  if k = me then raise exception 'That code is for you.'; end if;
  insert into __P__.kid_guardians (kid_id, guardian_id, added_by) values (k, me, auth.uid()) on conflict do nothing;
  delete from __Q__.kid_codes where code = upper(btrim(p_code));
  return (select name from __P__.customers where id = k);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404113, 4, 'patch', 'kids_mode:404113', $TPL$create or replace function __P__.kid_family(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if __Q__.my_staff_id() is null then raise exception 'Only staff can see this.'; end if;
  return jsonb_build_object(
    'parents', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', p.email) order by g.added_at), '[]'::jsonb) from __P__.kid_guardians g join __P__.customers p on p.id = g.guardian_id where g.kid_id = p_customer),
    'kids', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name) order by k.name), '[]'::jsonb) from __P__.kid_guardians g join __P__.customers k on k.id = g.kid_id where g.guardian_id = p_customer));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404114, 4, 'patch', 'kids_mode:404114', $TPL$create or replace function __P__.kid_link(p_kid uuid, p_parent uuid, p_on boolean default true) returns void language plpgsql security definer set search_path = '' as $f$
begin
  if not coalesce(__Q__.staff_role() in ('manager','front_desk'), false) then raise exception 'Only a manager or the front desk can do this.'; end if;
  if p_kid is null or p_parent is null or p_kid = p_parent then raise exception 'Choose the child and a parent.'; end if;
  if p_on then
    if exists (select 1 from __P__.kid_guardians where kid_id = p_parent) then raise exception 'A child cannot be a parent.'; end if;
    if exists (select 1 from __P__.kid_guardians where guardian_id = p_kid) then raise exception 'This customer is a parent, so they cannot be a child.'; end if;
    insert into __P__.kid_guardians (kid_id, guardian_id, added_by) values (p_kid, p_parent, auth.uid()) on conflict do nothing;
  else
    delete from __P__.kid_guardians where kid_id = p_kid and guardian_id = p_parent;
    delete from __Q__.kid_acting a where a.kid_id = p_kid and not exists (select 1 from __P__.kid_guardians g join __P__.customers c on c.id = g.guardian_id where g.kid_id = p_kid and c.user_id = a.user_id);
  end if;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198201, 11, 'patch', 'kids_mode:1198201', $TPL$revoke all on function __P__.kids_mine(), __P__.kid_add(text), __P__.kid_open(uuid), __P__.kid_share(uuid), __P__.kid_join(text), __P__.kid_family(uuid), __P__.kid_link(uuid, uuid, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198202, 11, 'patch', 'kids_mode:1198202', $TPL$grant execute on function __P__.kids_mine(), __P__.kid_add(text), __P__.kid_open(uuid), __P__.kid_share(uuid), __P__.kid_join(text), __P__.kid_family(uuid), __P__.kid_link(uuid, uuid, boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002702, 10, 'patch', 'kids_mode:1002702', $TPL$do $$
declare f text; d text; n text; done int := 0;
begin
  foreach f in array array['__Q__.chat_can(uuid)','__P__.chat_block(uuid)','__P__.chat_contacts()','__P__.chat_list()','__P__.chat_messages(uuid,timestamp with time zone)','__P__.chat_report(uuid,text)','__P__.chat_send(uuid,text)','__P__.chat_start(uuid,uuid,boolean)'] loop
    if to_regprocedure(f) is null then raise notice 'kids_mode: % not here, skipped', f; continue; end if;
    d := pg_get_functiondef(to_regprocedure(f));
    n := replace(d, '__Q__.customer_id()', '__Q__.chat_me()');
    if f = '__P__.chat_start(uuid,uuid,boolean)' then
      n := replace(n, 'p.customer_id = me_c and p.coach_id = p_staff', 'p.customer_id = any(__Q__.family(me_c)) and p.coach_id = p_staff');
      n := replace(n, 'cc.customer_id = me_c and cc.staff_id = p_staff', 'cc.customer_id = any(__Q__.family(me_c)) and cc.staff_id = p_staff');
      n := replace(n, 'p.customer_id = p_customer and p.coach_id = coalesce(p_staff, me_s)', 'p.customer_id = any(__Q__.family(p_customer)) and p.coach_id = coalesce(p_staff, me_s)');
      n := regexp_replace(n, '(\nbegin\n)', E'\\1  p_customer := __Q__.chat_customer(p_customer);\n');
      if position('__Q__.chat_customer(p_customer)' in n) = 0 then raise exception 'chat_start not changed'; end if;
    elsif f = '__P__.chat_contacts()' then
      n := replace(n, 'from __P__.privates p where p.customer_id = me_c)', 'from __P__.privates p where p.customer_id = any(__Q__.family(me_c)))');
      n := replace(n, 'from __P__.customers c where not c.is_agency)', 'from __P__.customers c where not c.is_agency and not __Q__.is_kid(c.id))');
      n := replace(n, 'c.id in (select p.customer_id from __P__.privates p where p.coach_id = me_s)', 'c.id in (select __Q__.chat_customer(p.customer_id) from __P__.privates p where p.coach_id = me_s)');
    end if;
    if n = d then raise notice 'kids_mode: % already done or different, skipped', f; continue; end if;
    execute n; done := done + 1;
  end loop;
  if to_regprocedure('__P__.chat_group_save(uuid,text,uuid[],uuid[])') is not null then
    d := pg_get_functiondef('__P__.chat_group_save(uuid,text,uuid[],uuid[])'::regprocedure);
    n := replace(d, 'select distinct cid, c from unnest(coalesce(p_customers, ''{}''::uuid[])) c where c is not null', 'select distinct cid, __Q__.chat_customer(c) from unnest(coalesce(p_customers, ''{}''::uuid[])) c where c is not null');
    if n <> d then execute n; done := done + 1; end if;
  end if;
  -- push: the phone belongs to the login's own customer, not the child it has open
  if to_regprocedure('__P__.push_sub_save(text,text,text)') is not null then
    d := pg_get_functiondef('__P__.push_sub_save(text,text,text)'::regprocedure);
    n := replace(d, '__Q__.customer_id()', '__Q__.own_customer_id()');
    if n <> d then execute n; done := done + 1; end if;
  end if;
  raise notice 'kids_mode: % chat functions changed', done;
end $$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'kids_mode:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
