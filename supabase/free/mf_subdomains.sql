-- Each gym's own web address: <name>.muayfriend.com (the app) and <name>.muayfriend.com/site (its website).
-- The Cloudflare Worker in muayfriend-gyms/ asks mf_gym_by_sub which gym a name belongs to.
-- Old links (muayfriend.com/app/?g=<slug>) keep working.

alter table mf.gyms add column if not exists sub text;
create unique index if not exists gyms_sub_key on mf.gyms (sub);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'gyms_sub_ok') then
    alter table mf.gyms add constraint gyms_sub_ok check (sub is null or (sub ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' and sub !~ '--'));
  end if;
end $$;

-- names no gym can have (ours, or ones that would look official)
create or replace function mf.sub_reserved(p text) returns boolean language sql immutable as $$
  select p = any (array['www','app','apps','api','dash','admin','demo','site','sites','help','support','mail','email','smtp','status',
    'blog','docs','static','cdn','assets','muayfriend','muay','friend','login','signin','signup','account','billing','pay','stripe','test','dev','staging'])
$$;

-- a good free name from the gym's name: "Core Combat Sports" -> core-combat-sports (then -2, -3 if taken)
create or replace function mf.sub_for(p_name text) returns text language plpgsql stable set search_path to '' as $$
declare base text := left(trim(both '-' from regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g')), 34); s text; n int := 1;
begin
  if base = '' then base := 'gym'; end if;
  if mf.sub_reserved(base) then base := base || '-gym'; end if;
  s := base;
  while exists (select 1 from mf.gyms where sub = s) loop n := n + 1; s := base || '-' || n; end loop;
  return s;
end $$;

-- every new gym gets a web address straight away
create or replace function mf.gyms_sub_default() returns trigger language plpgsql set search_path to '' as $$
begin
  if new.sub is null then new.sub := mf.sub_for(new.name); end if;
  return new;
end $$;
drop trigger if exists gyms_sub_default on mf.gyms;
create trigger gyms_sub_default before insert on mf.gyms for each row execute function mf.gyms_sub_default();

-- gyms made before this
update mf.gyms set sub = 'corecombat' where slug = 'core_combat_sports' and sub is null and not exists (select 1 from mf.gyms where sub = 'corecombat');
do $$ declare g record; begin
  for g in select slug, name from mf.gyms where sub is null order by made_at loop
    update mf.gyms set sub = mf.sub_for(g.name) where slug = g.slug;
  end loop;
end $$;

-- the Worker: which gym is <name>.muayfriend.com, its name and colours for the home screen icon
-- (only gyms that are ready; null for anything else)
drop function if exists public.mf_gym_by_sub(text);
create or replace function public.mf_gym_by_sub(p_sub text) returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare g record; th jsonb;
begin
  select slug, name, schema_pub into g from mf.gyms where status = 'ready' and sub = lower(btrim(coalesce(p_sub, ''))) limit 1;
  if g.slug is null then return null; end if;
  begin execute format('select value::jsonb from %I.app_settings where key = %L', g.schema_pub, 'app_theme') into th;
  exception when others then th := null; end;
  return jsonb_build_object('slug', g.slug, 'name', g.name, 'bg', th->>'bg', 'accent', th->>'accent');
end $$;
revoke all on function public.mf_gym_by_sub(text) from public;
grant execute on function public.mf_gym_by_sub(text) to anon, authenticated;

-- the app and Master control: a gym's web address
create or replace function public.mf_gym_sub(p_slug text) returns text language sql stable security definer set search_path to '' as $$
  select sub from mf.gyms where slug = p_slug and status = 'ready'
$$;
revoke all on function public.mf_gym_sub(text) from public;
grant execute on function public.mf_gym_sub(text) to anon, authenticated;

-- the team changes a gym's web address (Master control)
create or replace function public.mf_set_sub(p_slug text, p_sub text) returns text language plpgsql security definer set search_path to '' as $$
declare s text := lower(btrim(coalesce(p_sub, '')));
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can do this.'; end if;
  if s !~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' or s ~ '--' then raise exception 'Use 2 to 40 small letters, numbers or dashes.'; end if;
  if mf.sub_reserved(s) then raise exception 'That name is kept for Muay Friend. Pick another.'; end if;
  if exists (select 1 from mf.gyms where sub = s and slug <> p_slug) then raise exception 'Another gym already has that address.'; end if;
  update mf.gyms set sub = s where slug = p_slug;
  if not found then raise exception 'No gym with that name.'; end if;
  return s;
end $$;
revoke all on function public.mf_set_sub(text, text) from public, anon;
grant execute on function public.mf_set_sub(text, text) to authenticated;

notify pgrst, 'reload schema';
