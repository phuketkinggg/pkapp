-- Your gym website (feature gym_site): a fast two page website made from the app. Home (about, timetable, coaches, find us)
-- and Prices (memberships with Join, and a free trial request). The timetable, prices and coaches come straight from the app;
-- the words, photos and contact details from Settings, Website, Your gym website (app_settings key gym_site).

create or replace function public.gym_web() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare today date := (now() at time zone private.tz())::date; s jsonb;
begin
  if not private.feature('gym_site', false) then return jsonb_build_object('off', true); end if;
  s := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'gym_site'), '{}'::jsonb);
  return jsonb_build_object(
    'name', private.biz_main(),
    'site', s - 'hide',
    'theme', coalesce((select case when value ~ '^\s*\{' then value::jsonb end from public.app_settings where key = 'app_theme'), '{}'::jsonb),
    'region', public.app_region(),
    'trial', private.feature('gym_site_trial', true),
    'classes', coalesce((select jsonb_agg(jsonb_build_object('day', k.day, 'time', to_char(k.start_time, 'HH24:MI'), 'end', to_char(k.end_time, 'HH24:MI'),
        'title', k.title, 'discipline', k.discipline,
        'coach', (select string_agg(coalesce(nullif(btrim(s2.web_name), ''), s2.name), ', ' order by s2.name) from public.staff s2
                   where s2.active and not s2.support and (s2.id = any(coalesce(k.coach_ids, '{}')) or s2.id = k.coach_id))) order by k.day, k.start_time)
      from public.classes k where not (k.off_from is not null and k.off_from <= today and (k.off_to is null or k.off_to >= today))), '[]'::jsonb),
    'packages', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', p.price_thb, 'was', p.was_thb, 'badge', p.badge, 'notes', p.notes,
        'days', p.duration_days, 'week', p.per_week_limit, 'visits', p.visit_limit, 'covers', p.covers, 'tiers', p.tiers) order by p.price_thb desc nulls last, p.name)
      from public.packages p where p.active and private.can_buy(p.audience, 'standard') and (p.price_thb is not null or jsonb_array_length(coalesce(p.tiers, '[]'::jsonb)) > 0)
        and not (p.id::text in (select jsonb_array_elements_text(coalesce(s->'hide', '[]'::jsonb))))), '[]'::jsonb),
    'coaches', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(nullif(btrim(x.web_name), ''), x.name), 'title', x.web_title,
        'about', coalesce(nullif(btrim(x.web_about), ''), x.bio), 'photo', x.photo_url) order by x.web_sort nulls last, x.name)
      from public.staff x where x.active and x.web_show and not x.support), '[]'::jsonb));
end $f$;

-- someone asks for a free trial class on the website: they are added to Customers (or noted on their file) with the tag Free trial
create or replace function public.gym_web_trial(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare nm text := left(btrim(coalesce(p->>'name', '')), 80); em text := lower(left(btrim(coalesce(p->>'email', '')), 120));
  ph text := left(btrim(coalesce(p->>'phone', '')), 40); cl text := left(btrim(coalesce(p->>'class', '')), 120);
  msg text := left(btrim(coalesce(p->>'message', '')), 500); cid uuid; line text;
begin
  if not private.feature('gym_site', false) or not private.feature('gym_site_trial', true) then raise exception 'Free trials are not booked online here. Please get in touch.'; end if;
  if nm = '' then raise exception 'Please add your name.'; end if;
  if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'Please check your email address.'; end if;
  if (select count(*) from public.customers where lead_source = 'Website trial' and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many requests just now. Please try again later or get in touch.'; end if;
  line := to_char(now() at time zone private.tz(), 'DD Mon YYYY HH24:MI') || ' free trial request from the website' || case when cl <> '' then ': ' || cl else '' end
    || case when msg <> '' then E'\n' || msg else '' end;
  select id into cid from public.customers where lower(email) = em order by created_at limit 1;
  if cid is null then
    insert into public.customers (name, email, phone, lead_source, tags, notes) values (nm, em, nullif(ph, ''), 'Website trial', array['Free trial'], line) returning id into cid;
  else
    update public.customers set notes = left(coalesce(nullif(notes, '') || E'\n', '') || line, 4000), phone = coalesce(phone, nullif(ph, '')),
      tags = case when 'Free trial' = any(tags) then tags else tags || 'Free trial' end where id = cid;
  end if;
  return jsonb_build_object('ok', true);
end $f$;

revoke all on function public.gym_web() from public;
revoke all on function public.gym_web_trial(jsonb) from public;
grant execute on function public.gym_web() to anon, authenticated;
grant execute on function public.gym_web_trial(jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
