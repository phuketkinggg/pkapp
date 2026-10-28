-- Exercise groups (Coaching, Exercises): your own groups, for example Legs, Core or Shoulders.
-- An exercise can be in any number of groups. In a program you can add exercises from a group.

create table if not exists public.exercise_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  sort integer not null default 0,
  removed boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.exercise_groups enable row level security;
revoke all on public.exercise_groups from anon, authenticated;
alter table public.exercises add column if not exists group_ids uuid[] not null default '{}';

create or replace function public.exercise_list() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'name',e.name,'video',e.video,'notes',e.notes,
      'groups', coalesce((select jsonb_agg(g.id order by g.sort, lower(g.name)) from public.exercise_groups g where g.id = any (e.group_ids) and not g.removed), '[]'::jsonb))
    order by lower(e.name)) from public.exercises e where not e.removed),'[]'::jsonb);
end $f$;

create or replace function public.exercise_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v_id uuid := nullif(p->>'id','')::uuid; vid text := nullif(btrim(coalesce(p->>'video','')),''); gs uuid[];
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can do this.'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'Give the exercise a name.'; end if;
  if vid is not null and vid !~ '^https://' then raise exception 'The video link must start with https://'; end if;
  -- groups: only when sent, and only groups that exist
  if p ? 'groups' then
    select coalesce(array_agg(g.id), '{}') into gs from public.exercise_groups g
      where not g.removed and g.id::text in (select jsonb_array_elements_text(case when jsonb_typeof(p->'groups') = 'array' then p->'groups' else '[]'::jsonb end));
  end if;
  if v_id is null then insert into public.exercises(name,video,notes,created_by,group_ids) values (left(btrim(p->>'name'),120),vid,left(coalesce(p->>'notes',''),2000),private.my_staff_id(),coalesce(gs,'{}')) returning id into v_id;
  else update public.exercises set name=left(btrim(p->>'name'),120), video=vid, notes=left(coalesce(p->>'notes',''),2000), group_ids=coalesce(gs, group_ids), updated_at=now() where id=v_id and not removed;
    if not found then raise exception 'That exercise was not found.'; end if; end if;
  return v_id;
end $f$;

create or replace function public.exercise_groups_list() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,
      'count',(select count(*) from public.exercises e where not e.removed and g.id = any (e.group_ids))) order by g.sort, lower(g.name))
    from public.exercise_groups g where not g.removed), '[]'::jsonb);
end $f$;

-- add or rename a group; with "exercises" (a list of exercise ids) it also sets exactly which exercises are in it
create or replace function public.exercise_group_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare v_id uuid := nullif(p->>'id','')::uuid; nm text := btrim(coalesce(p->>'name','')); ids uuid[];
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can do this.'; end if;
  if nm = '' then raise exception 'Give the group a name.'; end if;
  if exists (select 1 from public.exercise_groups where not removed and lower(name) = lower(nm) and id is distinct from v_id) then raise exception 'There is already a group called %.', nm; end if;
  if v_id is null then insert into public.exercise_groups(name, sort) values (left(nm,60), coalesce((select max(sort)+1 from public.exercise_groups),0)) returning id into v_id;
  else update public.exercise_groups set name = left(nm,60) where id = v_id and not removed; if not found then raise exception 'That group was not found.'; end if; end if;
  if p ? 'exercises' and jsonb_typeof(p->'exercises') = 'array' then
    select coalesce(array_agg(x::uuid), '{}') into ids from jsonb_array_elements_text(p->'exercises') x where x ~ '^[0-9a-f-]{36}$';
    update public.exercises set group_ids = array_remove(group_ids, v_id) where v_id = any (group_ids) and not (id = any (ids));
    update public.exercises set group_ids = group_ids || v_id where id = any (ids) and not (v_id = any (group_ids)) and not removed;
  end if;
  return v_id;
end $f$;

-- remove a group: the exercises stay, only the group goes
create or replace function public.exercise_group_remove(p_id uuid) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can do this.'; end if;
  update public.exercise_groups set removed = true where id = p_id;
  update public.exercises set group_ids = array_remove(group_ids, p_id) where p_id = any (group_ids);
end $f$;

revoke all on function public.exercise_groups_list(), public.exercise_group_save(jsonb), public.exercise_group_remove(uuid) from public, anon;
grant execute on function public.exercise_groups_list(), public.exercise_group_save(jsonb), public.exercise_group_remove(uuid) to authenticated;
notify pgrst, 'reload schema';
