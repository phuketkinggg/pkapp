-- Arrival email: on the morning a guest arrives, a second email with today's classes, the map of the area and
-- the useful info from the welcome email (Settings, Welcome email, Arrival day email). Sent once per stay.
alter table public.stays add column if not exists arrival_sent_at timestamptz;
do $p$ begin
  if to_regclass('public.stay_emails') is not null then
    alter table public.stay_emails add column if not exists kind text not null default 'welcome';
  end if;
end $p$;
notify pgrst, 'reload schema';
