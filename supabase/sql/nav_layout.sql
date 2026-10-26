-- The menu on the left: the order, sort A to Z and group titles a manager chooses (Settings, Menu). Empty means the standard order.
insert into public.app_settings (key, value) values ('nav_layout', '{}') on conflict (key) do nothing;
