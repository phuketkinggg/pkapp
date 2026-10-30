-- Room offers for dates (Settings, Rooms and stays, Offers for dates): a website booking made with an offer remembers which one,
-- so an offer can be limited to the first so many bookings.
alter table public.stays add column if not exists web_promo text;
create index if not exists stays_web_promo on public.stays (web_promo) where web_promo is not null;
notify pgrst, 'reload schema';
