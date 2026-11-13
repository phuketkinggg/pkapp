-- More about each member in their file (date of birth, sex, height, blood type, how active, sleep, smoking, alcohol, how they
-- eat, family health history, their doctor), and the health questions after signing up (feature health_intake, on unless
-- switched off): a new member is asked once, after agreeing to us keeping their health details. Every question is optional.
-- Kept in member_file.about (jsonb). intake_at: when they answered or skipped, so they are asked only once.

alter table public.member_file add column if not exists about jsonb not null default '{}'::jsonb;
alter table public.member_file add column if not exists intake_at timestamptz;

-- only the known questions, short text, a real date of birth
create or replace function private.about_clean(p jsonb) returns jsonb language plpgsql immutable set search_path to '' as $f$
declare k text; v text; out jsonb := '{}'::jsonb; d date;
begin
  if jsonb_typeof(p) <> 'object' then return out; end if;
  foreach k in array array['birth','sex','height','blood','activity','sleep','smoke','alcohol','diet','family','doctor'] loop
    if not p ? k then continue; end if;
    v := left(btrim(coalesce(p->>k, '')), case when k = 'family' then 2000 else 200 end);
    if k = 'birth' and v <> '' then
      begin d := v::date; exception when others then d := null; end;
      if d is null or d < date '1900-01-01' or d > current_date then v := ''; else v := d::text; end if;
    end if;
    out := out || jsonb_build_object(k, v);
  end loop;
  return out;
end $f$;

-- the member, in their app. p_done: they finished (or skipped) the questions after signing up
create or replace function public.my_file_about(p jsonb, p_done boolean) returns void
language plpgsql security definer set search_path to '' as $f$
declare cid uuid := private.customer_id(); a jsonb := private.about_clean(coalesce(p, '{}'::jsonb)); cons timestamptz;
begin
  if cid is null then raise exception 'Sign in first.'; end if;
  select consent_at into cons from public.member_file where customer_id = cid;
  if cons is null and exists (select 1 from jsonb_each_text(a) x where x.value <> '') then raise exception 'Agree to us keeping your health details first.'; end if;
  insert into public.member_file as f (customer_id, about, intake_at, updated_at, updated_by)
    values (cid, (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(a) x where x.value <> '""'::jsonb), case when p_done then now() end, now(), 'Member')
  on conflict (customer_id) do update set
    about = (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(f.about || a) x where x.value <> '""'::jsonb),
    intake_at = case when p_done then coalesce(f.intake_at, now()) else f.intake_at end,
    updated_at = now(), updated_by = 'Member';
end $f$;
revoke all on function public.my_file_about(jsonb, boolean) from public, anon;
grant execute on function public.my_file_about(jsonb, boolean) to authenticated;

-- coaches and managers who may see the member's health
create or replace function public.member_file_about_save(p_customer uuid, p jsonb) returns void
language plpgsql security definer set search_path to '' as $f$
declare me uuid := private.my_staff_id(); nm text; a jsonb := private.about_clean(coalesce(p, '{}'::jsonb));
begin
  if me is null or not private.health_can(p_customer) then raise exception 'Not allowed.'; end if;
  select name into nm from public.staff where id = me;
  insert into public.member_file as f (customer_id, about, updated_at, updated_by) values (p_customer, (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(a) x where x.value <> '""'::jsonb), now(), nm)
  on conflict (customer_id) do update set
    about = (select coalesce(jsonb_object_agg(x.key, x.value), '{}'::jsonb) from jsonb_each(f.about || a) x where x.value <> '""'::jsonb),
    updated_at = now(), updated_by = nm;
end $f$;
revoke all on function public.member_file_about_save(uuid, jsonb) from public, anon;
grant execute on function public.member_file_about_save(uuid, jsonb) to authenticated;

-- my_file tells the app whether to ask the questions
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.my_file()') is null then raise notice 'no member file here, skipped'; return; end if;
  d := pg_get_functiondef('public.my_file()'::regprocedure);
  if position('ask_intake' in d) > 0 then raise notice 'my_file already patched'; return; end if;
  n := replace(d, $x$    'coaches', coalesce($x$,
    $x$    'ask_intake', private.feature('health_intake', true) and not exists (select 1 from public.member_file f2 where f2.customer_id = cid and f2.intake_at is not null),
    'coaches', coalesce($x$);
  if n = d then raise notice 'my_file: older version, skipped'; return; end if;
  execute n;
  if position('ask_intake' in pg_get_functiondef('public.my_file()'::regprocedure)) = 0 then raise exception 'my_file patch did not apply'; end if;
end $p$;

notify pgrst, 'reload schema';
