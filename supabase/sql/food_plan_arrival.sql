-- Food plans on arrival (feature: food_plans): the food plans of each stay for the Stays page, and a phone notice to the kitchen
-- when a guest with a food plan checks in ("Room LV3 checked in: Meal plan, 3 meals a day"). Who gets it: app_settings
-- arrival_push_roles (a list of roles), by default kitchen, front desk and managers. Sent through the chat function (mode push).

-- the food plans that overlap each stay (Stays shows them on the stay)
create or replace function public.food_plans_stays(p_ids uuid[]) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if coalesce(private.staff_role(),'') not in ('manager','admin','front_desk','resort','kitchen') then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('stay_id', s.id, 'plans', x.plans)) from public.stays s
    cross join lateral (select string_agg(distinct f.name || coalesce(', ' || f.per_day || ' a day', ''), '; ') plans
      from public.food_plans f where f.customer_id = s.customer_id and not f.removed
        and f.starts_on <= s.check_out and coalesce(f.ends_on, s.check_out) >= s.check_in) x
    where s.id = any(p_ids) and x.plans is not null), '[]'::jsonb);
end $f$;
revoke all on function public.food_plans_stays(uuid[]) from public, anon;
grant execute on function public.food_plans_stays(uuid[]) to authenticated;

-- who to tell, and what (the chat function sends it)
create or replace function public.push_targets(p_kind text, p_id uuid) returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare s public.stays; who text; room text; plans text; roles text[];
begin
  if p_kind <> 'arrival' then return null; end if;
  if not private.feature('food_plans', true) then return null; end if;
  select * into s from public.stays where id = p_id;
  if s.id is null then return null; end if;
  select string_agg(distinct f.name || coalesce(', ' || f.per_day || ' a day', ''), '; ') into plans
    from public.food_plans f where f.customer_id = s.customer_id and not f.removed and f.starts_on <= s.check_out and coalesce(f.ends_on, s.check_out) >= s.check_in;
  if plans is null then return null; end if;
  select name into who from public.customers where id = s.customer_id;
  select name into room from public.rooms where id = s.room_id;
  roles := coalesce((select array(select jsonb_array_elements_text(a.value::jsonb)) from public.app_settings a where a.key = 'arrival_push_roles' and a.value ~ '^\s*\['),
    array['kitchen','front_desk','manager']);
  return jsonb_build_object(
    'title', coalesce(room, 'A guest') || ' checked in with a food plan',
    'body', left(coalesce(who, 'Guest') || ': ' || plans || '. Until ' || to_char(s.check_out, 'FMDD Mon') || '.', 180),
    'tag', 'arrival-' || s.id, 'url', '#kitchen',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth))
      from public.push_subs p join public.staff st on st.id = p.staff_id
      where p.off_at is null and st.active and st.role = any (roles)), '[]'::jsonb));
end $f$;
revoke all on function public.push_targets(text, uuid) from public, anon, authenticated;
grant execute on function public.push_targets(text, uuid) to service_role;

-- a stay is checked in: ask the chat function to send it (never blocks the check in)
create or replace function private.stay_arrival_push() returns trigger language plpgsql security definer set search_path to '' as $f$
declare tok text; base text;
begin
  if new.status is distinct from 'in' or old.status is not distinct from 'in' then return null; end if;
  if not private.feature('food_plans', true) then return null; end if;
  if not exists (select 1 from public.food_plans f where f.customer_id = new.customer_id and not f.removed and f.starts_on <= new.check_out and coalesce(f.ends_on, new.check_out) >= new.check_in) then return null; end if;
  select value into tok from private.sync_settings where key = 'sync_token';
  select value into base from private.sync_settings where key = 'functions_url';
  perform net.http_post(url := coalesce(base, 'https://jijnshwduhgegacfvpkh.supabase.co/functions/v1') || '/chat',
    body := jsonb_build_object('mode', 'push', 'kind', 'arrival', 'id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-token', coalesce(tok, '')));
  return null;
exception when others then return null;
end $f$;
do $$ begin
  if to_regclass('public.food_plans') is null or to_regclass('public.push_subs') is null then raise notice 'no food plans or push here, trigger skipped'; return; end if;
  drop trigger if exists stays_arrival_push on public.stays;
  create trigger stays_arrival_push after update of status on public.stays for each row execute function private.stay_arrival_push();
end $$;
notify pgrst, 'reload schema';
