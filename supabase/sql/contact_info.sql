-- Contact info (Settings, General, Contact info): the business's phone, WhatsApp, email, LINE, more numbers
-- (for example one for Thai speakers), address and social pages, kept in one place.
-- The website reads it, so changing a number in the app changes it on every page.
-- Stored in app_settings key contact_info (managers save it from the app, like every other setting).

create or replace function public.contact_info() returns jsonb language sql stable security definer set search_path = '' as $f$
  select coalesce((select case when a.value ~ '^\s*\{' then (
      select jsonb_object_agg(k, v) from jsonb_each(a.value::jsonb) x(k, v)
      where k in ('phone','whatsapp','email','line','address','instagram','facebook','youtube','tiktok','extra')) end
    from public.app_settings a where a.key = 'contact_info'), '{}'::jsonb)
$f$;
revoke all on function public.contact_info() from public;
grant execute on function public.contact_info() to anon, authenticated;

notify pgrst, 'reload schema';
