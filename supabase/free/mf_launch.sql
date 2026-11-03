-- Muay Friend launch offer: the launch price is for the first 100 gyms, or until the end date, whichever comes first.
-- The counter on muayfriend.com is real: it counts gyms made in the app (test gyms of the team and example.com addresses are left out).
-- Change the numbers in mf.cfg: launch_cap (100) and launch_ends (end of 30 November 2026, Bangkok time).
insert into mf.cfg (key, value) values ('launch_cap', '100'::jsonb) on conflict (key) do nothing;
insert into mf.cfg (key, value) values ('launch_ends', to_jsonb('2026-11-30T23:59:59+07:00'::text)) on conflict (key) do nothing;

create or replace function public.mf_launch() returns jsonb language sql stable security definer set search_path to '' as $$
  with c as (
    select coalesce((select (value #>> '{}')::int from mf.cfg where key = 'launch_cap'), 100) cap,
           coalesce((select (value #>> '{}')::timestamptz from mf.cfg where key = 'launch_ends'), '2026-11-30T23:59:59+07:00') ends,
           (select count(*) from mf.gyms g where g.status = 'ready'
              and lower(g.owner_email) not like '%@example.com'
              and lower(g.owner_email) not in (select lower(x) from jsonb_array_elements_text(coalesce((select value from mf.cfg where key = 'team_emails'), '[]'::jsonb)) x)) used)
  select jsonb_build_object('cap', cap, 'used', used, 'left', greatest(0, cap - used), 'ends', ends,
    'open', used < cap and now() < ends) from c
$$;
revoke all on function public.mf_launch() from public;
grant execute on function public.mf_launch() to anon, authenticated;
notify pgrst, 'reload schema';
