-- Master control for the Muay Friend team (muayfriend.com/dash): every gym listed, open any gym's back office as tech support,
-- change its plan, and fix its features on or off. Only for the team emails in mf.cfg team_emails.

update mf.cfg set value = (select jsonb_agg(distinct x) from jsonb_array_elements_text(value || '["hello@phuketking.com"]'::jsonb) x)
  where key = 'team_emails';

-- the team sees every gym in the gym picker, everyone else only their own
create or replace function public.mf_my_gyms() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare g record; out jsonb := '[]'; ok boolean; team boolean := public.mf_is_team();
begin
  if auth.uid() is null then return '[]'; end if;
  for g in select * from mf.gyms where status = 'ready' order by name loop
    if team then ok := true; else
      execute format('select exists (select 1 from %I.staff where user_id = $1 and active) or exists (select 1 from %I.customers where user_id = $1)', g.schema_pub, g.schema_pub) into ok using auth.uid();
    end if;
    if ok then out := out || jsonb_build_array(jsonb_build_object('slug', g.slug, 'name', g.name)); end if;
  end loop;
  return out;
end $f$;

-- the team changes a gym's plan by hand (for example a free gym given every feature): status comp means given free, not paid
create or replace function public.mf_gym_plan(p_slug text, p_plan text, p_status text) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare g record;
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can do this.'; end if;
  select * into g from mf.gyms where slug = p_slug;
  if g is null then raise exception 'No gym with that name.'; end if;
  if g.stripe_sub is not null and coalesce(g.plan_status, '') in ('active', 'trialing', 'past_due') then
    raise exception 'This gym pays by card. Change its plan in Stripe, or cancel the card plan first.'; end if;
  return mf.set_plan(p_slug, p_plan, case when coalesce(p_plan, 'free') = 'free' then jsonb_build_object('status', '', 'cycle', '')
    else jsonb_build_object('status', case when p_status in ('comp', 'trialing') then p_status else 'comp' end, 'cycle', 'free') end);
end $f$;
revoke all on function public.mf_gym_plan(text, text, text) from public, anon;
grant execute on function public.mf_gym_plan(text, text, text) to authenticated;

notify pgrst, 'reload schema';
