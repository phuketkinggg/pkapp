-- Jobs for more than one person, and privates with more than one coach and more than one person.
-- Feature switches: job_team (jobs) and private_team (privates).
--
-- Jobs: room_issues.also_to holds the extra people. assigned_to stays the first person, so older screens still work.
-- Privates: the main private keeps the price, the payment and the main coach. Each extra coach gets a linked row
--   (lead_id = the main private, price 0, its own coach pay), so the coach sees it, is blocked for that time and is paid
--   through Commission like any private. The extra people are in also_customers on the main private and see it in their app.

alter table public.room_issues add column if not exists also_to uuid[] not null default '{}';
alter table public.privates add column if not exists lead_id uuid references public.privates(id) on delete cascade;
alter table public.privates add column if not exists also_customers uuid[] not null default '{}';
create unique index if not exists privates_lead_coach on public.privates (lead_id, coach_id) where lead_id is not null;

-- ---------- jobs ----------
do $$ declare s text;
begin
  s := pg_get_functiondef('private.action_row(public.room_issues)'::regprocedure);
  if s not like '%also_to%' then
    s := replace(s, $a$'assigned',(select name from public.staff where id=r.assigned_to)$a$,
      $a$'also_to',to_jsonb(r.also_to),'assigned',(select string_agg(s.name, ', ' order by (s.id = r.assigned_to) desc, s.name) from public.staff s where s.id = r.assigned_to or s.id = any(r.also_to))$a$);
    if s like '%also_to%' then execute s; else raise notice 'action_row is a different version here: skipped.'; end if;
  end if;

  s := pg_get_functiondef('public.actions_list()'::regprocedure);
  if s not like '%also_to%' then
    s := replace(s, 'r.assigned_to=me_s or', 'r.assigned_to=me_s or me_s = any(r.also_to) or');
    if s like '%also_to%' then execute s; else raise notice 'actions_list is a different version here: skipped.'; end if;
  end if;

  s := pg_get_functiondef('public.action_done(uuid,text)'::regprocedure);
  if s not like '%also_to%' then
    s := replace(s, 'or r.assigned_to=me_s)', 'or r.assigned_to=me_s or me_s = any(r.also_to))');
    if s like '%also_to%' then execute s; else raise notice 'action_done is a different version here: skipped.'; end if;
  end if;

  s := pg_get_functiondef('public.action_assign(uuid,uuid)'::regprocedure);
  if s not like '%also_to%' then
    s := replace(s, 'set assigned_to=p_staff,', $a$set assigned_to=p_staff, also_to='{}',$a$);
    if s like '%also_to%' then execute s; else raise notice 'action_assign is a different version here: skipped.'; end if;
  end if;
end $$;

-- give a job to one or more people (the first one is the main person); an empty list means nobody
create or replace function public.action_assign_team(p_id uuid, p_staff uuid[]) returns void language plpgsql security definer set search_path to '' as $$
declare ids uuid[];
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can give jobs to staff.'; end if;
  select coalesce(array_agg(x order by o), '{}') into ids from (select distinct on (x) x, o from unnest(coalesce(p_staff, '{}')) with ordinality u(x, o) where x is not null order by x, o) d;
  if exists (select 1 from unnest(ids) x where not exists (select 1 from public.staff s where s.id = x and coalesce(s.active,true) and s.role <> 'investor')) then
    raise exception 'Choose staff members who are working here.'; end if;
  update public.room_issues set assigned_to = ids[1], also_to = coalesce(ids[2:], '{}'),
    assigned_at = case when ids[1] is null then null when assigned_to is distinct from ids[1] or assigned_at is null then now() else assigned_at end
    where id = p_id and status = 'open';
  if not found then raise exception 'That job is not open any more.'; end if;
end $$;
revoke all on function public.action_assign_team(uuid, uuid[]) from public, anon;
grant execute on function public.action_assign_team(uuid, uuid[]) to authenticated;

-- ---------- privates ----------
-- an extra coach's row: no price of its own (the main private has it), never repriced
do $$ declare s text;
begin
  s := pg_get_functiondef('private.private_rate_trg()'::regprocedure);
  if s like '%lead_id%' then return; end if;
  s := regexp_replace(s, '(\nbegin\n)', E'\\1  if new.lead_id is not null then new.price_thb := 0; new.extra_thb := 0; new.extra_paid := false; new.extra_method := null; return new; end if;\n');
  if s not like '%lead_id%' then raise notice 'private_rate_trg is a different version here: skipped.'; return; end if;
  execute s;
end $$;

-- the main private moved, changed length, status or guest name: the extra coaches' rows follow
create or replace function private.private_team_sync() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.lead_id is not null then return null; end if;
  if (new.date, new.start_time, new.minutes, new.status, new.guest_name, new.customer_id) is not distinct from (old.date, old.start_time, old.minutes, old.status, old.guest_name, old.customer_id) then return null; end if;
  update public.privates t set date = new.date, start_time = new.start_time, minutes = new.minutes, guest_name = new.guest_name, customer_id = new.customer_id,
    status = case when new.status = 'requested' then 'confirmed' else new.status end
    where t.lead_id = new.id
      and (t.date, t.start_time, t.minutes, t.status, t.guest_name, t.customer_id) is distinct from (new.date, new.start_time, new.minutes, case when new.status = 'requested' then 'confirmed' else new.status end, new.guest_name, new.customer_id);
  return null;
end $$;
drop trigger if exists privates_team_sync on public.privates;
create trigger privates_team_sync after update of date, start_time, minutes, status, guest_name, customer_id on public.privates
  for each row execute function private.private_team_sync();

-- set the extra coaches (with what each gets) and the extra people on a private. p_share null: each extra coach gets the same as the main coach.
create or replace function public.private_team(p_id uuid, p_coaches uuid[], p_share int, p_people uuid[]) returns jsonb language plpgsql security definer set search_path to '' as $$
declare l public.privates; ids uuid[]; ppl uuid[]; sh int; c uuid; t public.privates;
begin
  if not (private.is_desk() or coalesce(private.staff_role(),'') = 'manager') then raise exception 'Only the desk or a manager can change who is on a private.'; end if;
  select * into l from public.privates where id = p_id;
  if l.id is null then raise exception 'That private was not found.'; end if;
  if l.lead_id is not null then raise exception 'Change the main private, not the extra coach''s copy.'; end if;
  select coalesce(array_agg(distinct x), '{}') into ids from unnest(coalesce(p_coaches, '{}')) x where x is not null and x is distinct from l.coach_id;
  select coalesce(array_agg(distinct x), '{}') into ppl from unnest(coalesce(p_people, '{}')) x where x is not null and x is distinct from l.customer_id;
  if array_length(ids, 1) > 8 then raise exception 'Up to 8 extra coaches.'; end if;
  if array_length(ppl, 1) > 30 then raise exception 'Up to 30 extra people.'; end if;
  if exists (select 1 from unnest(ids) x where not exists (select 1 from public.staff s where s.id = x and coalesce(s.active,true))) then raise exception 'Choose coaches who work here.'; end if;
  if exists (select 1 from unnest(ppl) x where not exists (select 1 from public.customers k where k.id = x)) then raise exception 'One of the people was not found.'; end if;
  sh := coalesce(p_share, l.coach_share_thb, round((coalesce(l.price_thb,0) - coalesce(l.fee_thb,0) - coalesce(l.tax_thb,0) + coalesce(l.extra_thb,0)) * coalesce(l.coach_pct,50) / 100.0)::int);
  if sh < 0 then raise exception 'The coach pay can not be below 0.'; end if;
  if l.also_customers is distinct from ppl then update public.privates set also_customers = ppl where id = l.id; end if;
  -- coaches taken off
  for t in select * from public.privates where lead_id = l.id and not (coach_id = any(ids)) loop
    if t.payout_id is not null then raise exception '% was already paid commission for this private. Undo that payment in Commission first.', (select name from public.staff where id = t.coach_id); end if;
    delete from public.privates where id = t.id;
  end loop;
  -- coaches added or kept
  foreach c in array ids loop
    select * into t from public.privates where lead_id = l.id and coach_id = c;
    if t.id is null then
      insert into public.privates (lead_id, customer_id, guest_name, coach_id, date, start_time, minutes, status, price_thb, paid, coach_share_thb, coach_pct, notes, any_coach)
        values (l.id, l.customer_id, l.guest_name, c, l.date, l.start_time, l.minutes, case when l.status = 'requested' then 'confirmed' else l.status end, 0, false, sh,
          coalesce((select commission_pct from public.staff where id = c), 50), 'Extra coach with ' || coalesce((select name from public.staff where id = l.coach_id), 'the main coach'), false);
    elsif t.coach_share_thb is distinct from sh and t.payout_id is null then
      update public.privates set coach_share_thb = sh where id = t.id;
    end if;
  end loop;
  return jsonb_build_object('coaches', coalesce(array_length(ids, 1), 0), 'people', coalesce(array_length(ppl, 1), 0), 'share', sh);
end $$;
revoke all on function public.private_team(uuid, uuid[], int, uuid[]) from public, anon;
grant execute on function public.private_team(uuid, uuid[], int, uuid[]) to authenticated;

-- the customer app: an extra coach's row is not shown twice; the extra people see the private too
do $$ declare s text; f text;
begin
  foreach f in array array['public.customer_home()', 'public.customer_home_as(uuid)'] loop
    if to_regprocedure(f) is null then continue; end if;
    s := pg_get_functiondef(f::regprocedure);
    if s like '%also_customers%' then continue; end if;
    s := replace(s, 'where p.customer_id = c.id and p.date >= v_today - 30)', 'where (p.customer_id = c.id and p.lead_id is null or c.id = any(p.also_customers)) and p.date >= v_today - 30)');
    if s like '%also_customers%' then execute s; else raise notice '% is a different version here: skipped.', f; end if;
  end loop;
end $$;

-- the coach app: the other people and the other coaches on the session
do $$ declare s text;
begin
  if to_regprocedure('public.coach_home()') is null then return; end if;
  s := pg_get_functiondef('public.coach_home()'::regprocedure);
  if s like '%also_customers%' then return; end if;
  s := replace(s, $a$                         else c.name end,
        'notes', p.notes,$a$, $a$                         else c.name end
          || coalesce(' + ' || (select string_agg(x.name, ', ' order by x.name) from public.customers x where x.id = any((select l.also_customers from public.privates l where l.id = coalesce(p.lead_id, p.id)))), '')
          || coalesce(' (with ' || (select string_agg(s2.name, ', ' order by s2.name) from public.privates o join public.staff s2 on s2.id = o.coach_id
               where (o.id = coalesce(p.lead_id, p.id) or o.lead_id = coalesce(p.lead_id, p.id)) and o.id <> p.id and o.status <> 'cancelled') || ')', ''),
        'notes', p.notes,$a$);
  if s like '%also_customers%' then execute s; else raise notice 'coach_home is a different version here: skipped.'; end if;
end $$;

-- a save from the app that leaves the extra people out (sends null) keeps the list empty, never fails
create or replace function private.privates_people_default() returns trigger language plpgsql set search_path to '' as $$
begin
  if new.also_customers is null then new.also_customers := case when tg_op = 'UPDATE' then coalesce(old.also_customers, '{}') else '{}' end; end if;
  return new;
end $$;
drop trigger if exists privates_aa_people on public.privates;
create trigger privates_aa_people before insert or update on public.privates for each row execute function private.privates_people_default();
