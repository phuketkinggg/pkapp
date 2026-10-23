-- Fighters are customers with a fighter profile: ring name, fight weight, and free or paid training (only staff see that).
-- Free fighters get a "Fight team training" pack (0 THB, no end, group Muay Thai classes and the Fitness Zone, not recovery),
-- so every check in works as normal (kiosk, desk, app) and is still counted. It is cancelled when they stop being free.
-- New fighters can join a coaching group by themselves (app_settings fighters.group_id).
alter table public.customers add column if not exists is_fighter boolean not null default false;
alter table public.customers add column if not exists fighter_name text check (char_length(fighter_name) <= 60);
alter table public.customers add column if not exists fighter_free boolean not null default false;
alter table public.customers add column if not exists fight_weight text check (char_length(fight_weight) <= 30);

insert into public.app_settings (key, value) select 'fighters', '{"group_id":null}'
where not exists (select 1 from public.app_settings where key = 'fighters');

create or replace function private.fighter_sync() returns trigger language plpgsql security definer set search_path to '' as $$
declare free_now boolean := new.is_fighter and new.fighter_free; grp uuid;
begin
  if free_now and not exists (select 1 from public.purchases p where p.customer_id = new.id and p.package_name = 'Fight team training' and not p.cancelled) then
    insert into public.purchases (customer_id, package_name, price_thb, price_group, paid, paid_thb, method, purchased_on, covers, cancelled)
    values (new.id, 'Fight team training', 0, coalesce(new.price_group, 'standard'), true, 0, null, private.bkk_today(), array['Muay Thai','Fitness zone','Open gym'], false);
  elsif not free_now then
    update public.purchases set cancelled = true where customer_id = new.id and package_name = 'Fight team training' and not cancelled and price_thb = 0;
  end if;
  if new.is_fighter and (tg_op = 'INSERT' or not old.is_fighter) then
    begin grp := nullif((select value::jsonb->>'group_id' from public.app_settings where key = 'fighters'), '')::uuid; exception when others then grp := null; end;
    if grp is not null and exists (select 1 from public.action_groups g where g.id = grp and not coalesce(g.removed, false))
       and not exists (select 1 from public.group_members m where m.group_id = grp and m.customer_id = new.id and not coalesce(m.removed, false)) then
      insert into public.group_members (group_id, customer_id, start_on, added_by) values (grp, new.id, private.bkk_today(), private.my_staff_id());
    end if;
  end if;
  return null;
end $$;
drop trigger if exists customers_fighter on public.customers;
create trigger customers_fighter after insert or update of is_fighter, fighter_free on public.customers for each row execute function private.fighter_sync();

-- the fighter card in the member app: ring name, record, next fight (null when not a fighter). Free or paid is never sent.
create or replace function public.customer_fighter() returns jsonb language sql stable security definer set search_path to '' as $$
  select case when c.is_fighter then jsonb_build_object(
    'name', c.fighter_name, 'weight', c.fight_weight,
    'record', (select jsonb_build_object('w', count(*) filter (where f.result = 'win'), 'l', count(*) filter (where f.result = 'loss'), 'd', count(*) filter (where f.result = 'draw'))
               from public.fights f where f.fighter_customer_id = c.id and not f.cancelled),
    'next', (select jsonb_build_object('date', f.fight_date, 'time', f.fight_time, 'venue', f.venue, 'opponent', f.opponent, 'weight', f.weight)
             from public.fights f where f.fighter_customer_id = c.id and not f.cancelled and f.result is null and f.fight_date >= private.bkk_today()
             order by f.fight_date, f.fight_time limit 1),
    'last', (select coalesce(jsonb_agg(x order by x->>'date' desc), '[]'::jsonb) from (
               select jsonb_build_object('date', f.fight_date, 'opponent', f.opponent, 'result', f.result, 'method', f.method, 'venue', f.venue) x
               from public.fights f where f.fighter_customer_id = c.id and not f.cancelled and f.result is not null order by f.fight_date desc limit 5) z))
  end
  from public.customers c where c.id = private.customer_id()
$$;
revoke all on function public.customer_fighter() from public, anon;
grant execute on function public.customer_fighter() to authenticated;
