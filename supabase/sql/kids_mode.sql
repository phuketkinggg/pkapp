-- Kids mode (feature kids_mode, off unless switched on): a child is a customer looked after by one or more parents.
-- A parent opens the child's app from their own login (packages, check ins, grading, technique videos), and can share the child with a second parent by a code.
-- Nobody can message a child: every chat, group and coach message goes to the parent, and a child who signs in has no messages.

create table if not exists public.kid_guardians (
  kid_id uuid not null references public.customers(id) on delete cascade,
  guardian_id uuid not null references public.customers(id) on delete cascade,
  added_by uuid,
  added_at timestamptz not null default now(),
  primary key (kid_id, guardian_id),
  check (kid_id <> guardian_id)
);
alter table public.kid_guardians enable row level security;
create index if not exists kid_guardians_guardian on public.kid_guardians(guardian_id);

-- which child's app a parent has open (one per login)
create table if not exists private.kid_acting (
  user_id uuid primary key,
  kid_id uuid not null,
  at timestamptz not null default now()
);
-- codes a parent shares so a second parent can join
create table if not exists private.kid_codes (
  code text primary key,
  kid_id uuid not null,
  made_by uuid,
  until timestamptz not null default now() + interval '7 days'
);

create or replace function private.kids_on() returns boolean language sql stable security definer set search_path = '' as $f$
  select private.feature('kids_mode', false)
$f$;

-- the customer of the login itself (never a child it has open)
create or replace function private.own_customer_id() returns uuid language sql stable security definer set search_path = '' as $f$
  select c.id from public.customers c where c.user_id = (select auth.uid()) order by c.created_at limit 1
$f$;

create or replace function private.is_kid(c uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select c is not null and private.kids_on() and exists (select 1 from public.kid_guardians g where g.kid_id = c)
$f$;

-- who a chat goes to: a child's first parent, everyone else themselves
create or replace function private.chat_customer(c uuid) returns uuid language sql stable security definer set search_path = '' as $f$
  select case when private.is_kid(c) then coalesce((select g.guardian_id from public.kid_guardians g where g.kid_id = c order by g.added_at limit 1), c) else c end
$f$;

-- a customer and the children they look after (for "has privates with" checks in chat)
create or replace function private.family(c uuid) returns uuid[] language sql stable security definer set search_path = '' as $f$
  select array[c] || case when private.kids_on() then coalesce((select array_agg(g.kid_id) from public.kid_guardians g where g.guardian_id = c), '{}'::uuid[]) else '{}'::uuid[] end
$f$;

-- the customer in chat: the login's own customer, and nobody when that customer is a child
create or replace function private.chat_me() returns uuid language sql stable security definer set search_path = '' as $f$
  select case when private.is_kid(x.id) then null else x.id end from (select private.own_customer_id() id) x
$f$;

-- everything a customer does in the app is for the child the parent has open, or for themselves
create or replace function private.customer_id() returns uuid language sql stable security definer set search_path = '' as $f$
  select coalesce(
    (select a.kid_id from private.kid_acting a
      where a.user_id = (select auth.uid()) and private.kids_on()
        and exists (select 1 from public.kid_guardians g where g.kid_id = a.kid_id and g.guardian_id = private.own_customer_id())),
    private.own_customer_id())
$f$;

-- the parent's kids, the child open now, and the other parents of each child
create or replace function public.kids_mine() returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare me uuid := private.own_customer_id();
begin
  if me is null or not private.kids_on() then return jsonb_build_object('on', private.kids_on(), 'kids', '[]'::jsonb, 'acting', null, 'me_kid', false); end if;
  return jsonb_build_object('on', true, 'me_kid', private.is_kid(me), 'me', me,
    'acting', (select a.kid_id from private.kid_acting a where a.user_id = auth.uid() and exists (select 1 from public.kid_guardians g where g.kid_id = a.kid_id and g.guardian_id = me)),
    'kids', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name,
        'parents', (select coalesce(jsonb_agg(p.name order by g2.added_at), '[]'::jsonb) from public.kid_guardians g2 join public.customers p on p.id = g2.guardian_id where g2.kid_id = k.id)) order by k.name), '[]'::jsonb)
      from public.kid_guardians g join public.customers k on k.id = g.kid_id where g.guardian_id = me));
end $f$;

-- a parent adds a child: a new customer looked after by them
create or replace function public.kid_add(p_name text) returns uuid language plpgsql security definer set search_path = '' as $f$
declare me uuid := private.own_customer_id(); n text := btrim(coalesce(p_name, '')); kid uuid;
begin
  if not private.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null then raise exception 'Sign in first.'; end if;
  if private.is_kid(me) then raise exception 'Ask your parent to do this.'; end if;
  if n = '' or char_length(n) > 80 then raise exception 'Write your child''s name.'; end if;
  if (select count(*) from public.kid_guardians where guardian_id = me) >= 8 then raise exception 'You can add up to 8 children.'; end if;
  insert into public.customers (name, lead_source, tags) values (n, 'kids', array['kid']) returning id into kid;
  insert into public.kid_guardians (kid_id, guardian_id, added_by) values (kid, me, auth.uid());
  return kid;
end $f$;

-- a parent opens a child's app, or goes back to their own (p_kid null)
create or replace function public.kid_open(p_kid uuid) returns void language plpgsql security definer set search_path = '' as $f$
declare me uuid := private.own_customer_id();
begin
  if p_kid is null then delete from private.kid_acting where user_id = auth.uid(); return; end if;
  if not private.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null or not exists (select 1 from public.kid_guardians g where g.kid_id = p_kid and g.guardian_id = me) then raise exception 'That child is not linked to you.'; end if;
  insert into private.kid_acting (user_id, kid_id) values (auth.uid(), p_kid) on conflict (user_id) do update set kid_id = excluded.kid_id, at = now();
end $f$;

-- a code for another parent to join (valid 7 days)
create or replace function public.kid_share(p_kid uuid) returns text language plpgsql security definer set search_path = '' as $f$
declare me uuid := private.own_customer_id(); c text;
begin
  if not private.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null or not exists (select 1 from public.kid_guardians g where g.kid_id = p_kid and g.guardian_id = me) then raise exception 'That child is not linked to you.'; end if;
  delete from private.kid_codes where until < now();
  loop
    c := upper(substr(translate(encode(extensions.gen_random_bytes(8), 'base64'), '+/=01OIl', ''), 1, 6));
    exit when char_length(c) = 6 and not exists (select 1 from private.kid_codes where code = c);
  end loop;
  insert into private.kid_codes (code, kid_id, made_by) values (c, p_kid, me);
  return c;
end $f$;

-- the second parent types the code
create or replace function public.kid_join(p_code text) returns text language plpgsql security definer set search_path = '' as $f$
declare me uuid := private.own_customer_id(); k uuid;
begin
  if not private.kids_on() then raise exception 'Kids mode is switched off.'; end if;
  if me is null then raise exception 'Sign in first.'; end if;
  if private.is_kid(me) then raise exception 'Ask your parent to do this.'; end if;
  select kid_id into k from private.kid_codes where code = upper(btrim(coalesce(p_code, ''))) and until > now();
  if k is null then raise exception 'That code is wrong or too old. Ask for a new one.'; end if;
  if k = me then raise exception 'That code is for you.'; end if;
  insert into public.kid_guardians (kid_id, guardian_id, added_by) values (k, me, auth.uid()) on conflict do nothing;
  delete from private.kid_codes where code = upper(btrim(p_code));
  return (select name from public.customers where id = k);
end $f$;

-- staff: the parents and children of a customer, for the customer page
create or replace function public.kid_family(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if private.my_staff_id() is null then raise exception 'Only staff can see this.'; end if;
  return jsonb_build_object(
    'parents', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', p.email) order by g.added_at), '[]'::jsonb) from public.kid_guardians g join public.customers p on p.id = g.guardian_id where g.kid_id = p_customer),
    'kids', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name) order by k.name), '[]'::jsonb) from public.kid_guardians g join public.customers k on k.id = g.kid_id where g.guardian_id = p_customer));
end $f$;

-- staff (manager or front desk): make a customer the child of a parent, or undo it
create or replace function public.kid_link(p_kid uuid, p_parent uuid, p_on boolean default true) returns void language plpgsql security definer set search_path = '' as $f$
begin
  if not coalesce(private.staff_role() in ('manager','front_desk'), false) then raise exception 'Only a manager or the front desk can do this.'; end if;
  if p_kid is null or p_parent is null or p_kid = p_parent then raise exception 'Choose the child and a parent.'; end if;
  if p_on then
    if exists (select 1 from public.kid_guardians where kid_id = p_parent) then raise exception 'A child cannot be a parent.'; end if;
    if exists (select 1 from public.kid_guardians where guardian_id = p_kid) then raise exception 'This customer is a parent, so they cannot be a child.'; end if;
    insert into public.kid_guardians (kid_id, guardian_id, added_by) values (p_kid, p_parent, auth.uid()) on conflict do nothing;
  else
    delete from public.kid_guardians where kid_id = p_kid and guardian_id = p_parent;
    delete from private.kid_acting a where a.kid_id = p_kid and not exists (select 1 from public.kid_guardians g join public.customers c on c.id = g.guardian_id where g.kid_id = p_kid and c.user_id = a.user_id);
  end if;
end $f$;

revoke all on function public.kids_mine(), public.kid_add(text), public.kid_open(uuid), public.kid_share(uuid), public.kid_join(text), public.kid_family(uuid), public.kid_link(uuid, uuid, boolean) from public, anon;
grant execute on function public.kids_mine(), public.kid_add(text), public.kid_open(uuid), public.kid_share(uuid), public.kid_join(text), public.kid_family(uuid), public.kid_link(uuid, uuid, boolean) to authenticated;

-- chat: always the login's own customer (never a child), children cannot be messaged, and chats for a child go to their parent
do $$
declare f text; d text; n text; done int := 0;
begin
  foreach f in array array['private.chat_can(uuid)','public.chat_block(uuid)','public.chat_contacts()','public.chat_list()','public.chat_messages(uuid,timestamp with time zone)','public.chat_report(uuid,text)','public.chat_send(uuid,text)','public.chat_start(uuid,uuid,boolean)'] loop
    if to_regprocedure(f) is null then raise notice 'kids_mode: % not here, skipped', f; continue; end if;
    d := pg_get_functiondef(to_regprocedure(f));
    n := replace(d, 'private.customer_id()', 'private.chat_me()');
    if f = 'public.chat_start(uuid,uuid,boolean)' then
      n := replace(n, 'p.customer_id = me_c and p.coach_id = p_staff', 'p.customer_id = any(private.family(me_c)) and p.coach_id = p_staff');
      n := replace(n, 'cc.customer_id = me_c and cc.staff_id = p_staff', 'cc.customer_id = any(private.family(me_c)) and cc.staff_id = p_staff');
      n := replace(n, 'p.customer_id = p_customer and p.coach_id = coalesce(p_staff, me_s)', 'p.customer_id = any(private.family(p_customer)) and p.coach_id = coalesce(p_staff, me_s)');
      n := regexp_replace(n, '(\nbegin\n)', E'\\1  p_customer := private.chat_customer(p_customer);\n');
      if position('private.chat_customer(p_customer)' in n) = 0 then raise exception 'chat_start not changed'; end if;
    elsif f = 'public.chat_contacts()' then
      n := replace(n, 'from public.privates p where p.customer_id = me_c)', 'from public.privates p where p.customer_id = any(private.family(me_c)))');
      n := replace(n, 'from public.customers c where not c.is_agency)', 'from public.customers c where not c.is_agency and not private.is_kid(c.id))');
      n := replace(n, 'c.id in (select p.customer_id from public.privates p where p.coach_id = me_s)', 'c.id in (select private.chat_customer(p.customer_id) from public.privates p where p.coach_id = me_s)');
    end if;
    if n = d then raise notice 'kids_mode: % already done or different, skipped', f; continue; end if;
    execute n; done := done + 1;
  end loop;
  if to_regprocedure('public.chat_group_save(uuid,text,uuid[],uuid[])') is not null then
    d := pg_get_functiondef('public.chat_group_save(uuid,text,uuid[],uuid[])'::regprocedure);
    n := replace(d, 'select distinct cid, c from unnest(coalesce(p_customers, ''{}''::uuid[])) c where c is not null', 'select distinct cid, private.chat_customer(c) from unnest(coalesce(p_customers, ''{}''::uuid[])) c where c is not null');
    if n <> d then execute n; done := done + 1; end if;
  end if;
  -- push: the phone belongs to the login's own customer, not the child it has open
  if to_regprocedure('public.push_sub_save(text,text,text)') is not null then
    d := pg_get_functiondef('public.push_sub_save(text,text,text)'::regprocedure);
    n := replace(d, 'private.customer_id()', 'private.own_customer_id()');
    if n <> d then execute n; done := done + 1; end if;
  end if;
  raise notice 'kids_mode: % chat functions changed', done;
end $$;

-- the home screen and the member card show the child the parent has open
do $$
declare d text; n text;
begin
  if to_regprocedure('public.customer_home()') is not null then
    d := pg_get_functiondef('public.customer_home()'::regprocedure);
    n := replace(d, 'select * into c from public.customers where user_id = v_uid order by created_at limit 1;', 'select * into c from public.customers where id = private.customer_id();');
    if n <> d then execute n; elsif position('private.customer_id()' in d) = 0 then raise notice 'kids_mode: customer_home is different, skipped'; end if;
  end if;
  if to_regprocedure('public.my_card()') is not null then
    d := pg_get_functiondef('public.my_card()'::regprocedure);
    n := replace(d, 'from public.customers where user_id = auth.uid() order by created_at limit 1;', 'from public.customers where id = private.customer_id();');
    if n <> d then execute n; end if;
  end if;
end $$;
