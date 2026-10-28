-- Managers can add a new setting, not only change one that exists (the same rule as changing).
-- Without this, saving a setting for the first time (for example Partner levels) said "You are not allowed to do that".
do $p$
begin
  if not exists (select 1 from pg_policy where polrelid = 'public.app_settings'::regclass and polname = 'settings_insert') then
    create policy settings_insert on public.app_settings for insert to authenticated
      with check ((select private.staff_role()) = 'manager');
  end if;
end $p$;

-- the partner levels start as the defaults, so they can be changed
insert into public.app_settings (key, value)
select 'partner_levels', private.partner_levels()::text
where not exists (select 1 from public.app_settings where key = 'partner_levels')
  and to_regprocedure('private.partner_levels()') is not null;
