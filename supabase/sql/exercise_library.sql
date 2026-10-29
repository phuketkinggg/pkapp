-- One home for technique videos (feature: techniques): every video lives in Coaching, Exercises.
-- An exercise can be shared in the technique library (Education), with a category and who can watch it.
-- The two stay the same: changing the name, video or coaching points on one changes the other.
-- Videos added in the technique library become exercises by themselves.

alter table public.techniques add column if not exists exercise_id uuid references public.exercises(id) on delete set null;
create unique index if not exists techniques_exercise on public.techniques (exercise_id) where exercise_id is not null;

-- exercise changed: its library video follows
create or replace function private.ex_to_tech() returns trigger language plpgsql security definer set search_path to '' as $f$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  if new.removed then
    update public.techniques set removed = true, updated_at = now() where exercise_id = new.id and not removed;
  else
    update public.techniques set title = new.name, body = new.notes,
      video_url = case when coalesce(new.video, '') ~ '^https://' then new.video else video_url end, updated_at = now()
    where exercise_id = new.id and (title is distinct from new.name or body is distinct from new.notes or (coalesce(new.video, '') ~ '^https://' and video_url is distinct from new.video));
  end if;
  return null;
end $f$;
drop trigger if exists exercises_to_tech on public.exercises;
create trigger exercises_to_tech after update of name, video, notes, removed on public.exercises for each row execute function private.ex_to_tech();

-- library video added or changed: its exercise follows (a new library video becomes an exercise)
create or replace function private.tech_to_ex() returns trigger language plpgsql security definer set search_path to '' as $f$
declare eid uuid;
begin
  if pg_trigger_depth() > 1 or new.removed then return null; end if;
  if new.exercise_id is null then
    insert into public.exercises (name, video, notes, created_by) values (left(new.title, 120), new.video_url, left(coalesce(new.body, ''), 2000), private.my_staff_id()) returning id into eid;
    update public.techniques set exercise_id = eid where id = new.id;
  else
    update public.exercises set name = left(new.title, 120), notes = left(coalesce(new.body, ''), 2000),
      video = coalesce(new.video_url, video), updated_at = now()
    where id = new.exercise_id and (name is distinct from left(new.title, 120) or notes is distinct from left(coalesce(new.body, ''), 2000) or (new.video_url is not null and video is distinct from new.video_url));
  end if;
  return null;
end $f$;
drop trigger if exists techniques_to_ex on public.techniques;
create trigger techniques_to_ex after insert or update of title, video_url, body, removed on public.techniques for each row execute function private.tech_to_ex();

-- the videos already in the library become exercises
do $m$
declare t public.techniques; eid uuid;
begin
  for t in select * from public.techniques where exercise_id is null and not removed loop
    insert into public.exercises (name, video, notes) values (left(t.title, 120), t.video_url, left(coalesce(t.body, ''), 2000)) returning id into eid;
    update public.techniques set exercise_id = eid where id = t.id;
  end loop;
end $m$;

-- the exercise list also says whether each one is in the library
create or replace function public.exercise_list() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.coach_staff() then raise exception 'Only coaches and managers can see this.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'name',e.name,'video',e.video,'notes',e.notes,
      'groups', coalesce((select jsonb_agg(g.id order by g.sort, lower(g.name)) from public.exercise_groups g where g.id = any (e.group_ids) and not g.removed), '[]'::jsonb),
      'share', (select jsonb_build_object('id', t.id, 'slug', t.slug, 'category', t.category, 'visibility', t.visibility) from public.techniques t where t.exercise_id = e.id and not t.removed))
    order by lower(e.name)) from public.exercises e where not e.removed),'[]'::jsonb);
end $f$;

-- share an exercise in the technique library, change its category or who can watch, or take it out (manager)
create or replace function public.exercise_share(p_exercise uuid, p jsonb) returns uuid language plpgsql security definer set search_path to '' as $f$
declare e public.exercises; t public.techniques; s text; base text; n int := 1; vis text := coalesce(nullif(p->>'visibility',''), 'app');
begin
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change the technique library.'; end if;
  select * into e from public.exercises where id = p_exercise and not removed;
  if e.id is null then raise exception 'That exercise was not found.'; end if;
  select * into t from public.techniques where exercise_id = e.id;
  if not coalesce((p->>'on')::boolean, false) then
    update public.techniques set removed = true, updated_at = now() where exercise_id = e.id and not removed;
    return null;
  end if;
  if vis not in ('public','app','members','hidden') then raise exception 'Choose who can watch it.'; end if;
  if coalesce(e.video, '') !~ '^https://' and t.video_path is null then raise exception 'Add a video to the exercise first.'; end if;
  if t.id is null then
    base := left(trim(both '-' from regexp_replace(lower(e.name), '[^a-z0-9]+', '-', 'g')), 70); if base = '' then base := 'technique'; end if;
    s := base; while exists (select 1 from public.techniques where slug = s) loop n := n + 1; s := base || '-' || n; end loop;
    insert into public.techniques (slug, title, category, video_url, body, visibility, exercise_id)
    values (s, e.name, left(btrim(coalesce(p->>'category','')), 60), case when coalesce(e.video,'') ~ '^https://' then e.video end, e.notes, vis, e.id) returning * into t;
  else
    update public.techniques set removed = false, category = left(btrim(coalesce(p->>'category','')), 60), visibility = vis, title = e.name, body = e.notes,
      video_url = case when coalesce(e.video,'') ~ '^https://' then e.video else video_url end, updated_at = now() where id = t.id;
  end if;
  return t.id;
end $f$;
revoke all on function public.exercise_share(uuid, jsonb) from public, anon;
grant execute on function public.exercise_share(uuid, jsonb) to authenticated;
revoke all on function private.ex_to_tech(), private.tech_to_ex() from public, anon, authenticated;

notify pgrst, 'reload schema';
