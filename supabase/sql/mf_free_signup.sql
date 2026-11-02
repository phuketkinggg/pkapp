-- Muay Friend free version: gyms sign up on muayfriend.com ("Start free"). Saved in mf_leads with plan 'free'
-- (or 'free_waitlist' once the free spots are taken). The number of free spots is the setting mf_free_cap (default 50).
-- Only on the live database: mf_leads is the Muay Friend sales list, it does not exist in the gym demos.
alter table public.mf_leads add column if not exists plan text;
alter table public.mf_leads add column if not exists social text;
alter table public.mf_leads add column if not exists status text not null default 'new';
alter table public.mf_leads add column if not exists welcomed boolean;
alter table public.mf_leads add column if not exists welcome_error text;
create index if not exists mf_leads_plan on public.mf_leads (plan) where plan is not null;
insert into public.app_settings (key, value) values ('mf_free_cap', '50') on conflict (key) do nothing;
