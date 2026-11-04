-- A package can carry a badge (for example Best seller or New) and a normal price shown crossed out (was_thb),
-- so a promotion stands out on the website prices page, in the customer app and at the desk. Both are optional.
alter table public.packages add column if not exists badge text;
alter table public.packages add column if not exists was_thb integer;
notify pgrst, 'reload schema';
