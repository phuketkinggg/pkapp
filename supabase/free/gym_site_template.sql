delete from mf.template where name like 'gym_site:%';
insert into mf.template (ord, phase, kind, name, sql) values (403601, 4, 'patch', 'gym_site:403601', $TPL$create or replace function __P__.gym_web() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare today date := (now() at time zone __Q__.tz())::date; s jsonb;
begin
  if not __Q__.feature('gym_site', false) then return jsonb_build_object('off', true); end if;
  s := coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'gym_site'), '{}'::jsonb);
  return jsonb_build_object(
    'name', __Q__.biz_main(),
    'site', s - 'hide',
    'theme', coalesce((select case when value ~ '^\s*\{' then value::jsonb end from __P__.app_settings where key = 'app_theme'), '{}'::jsonb),
    'region', __P__.app_region(),
    'trial', __Q__.feature('gym_site_trial', true),
    'classes', coalesce((select jsonb_agg(jsonb_build_object('day', k.day, 'time', to_char(k.start_time, 'HH24:MI'), 'end', to_char(k.end_time, 'HH24:MI'),
        'title', k.title, 'discipline', k.discipline,
        'coach', (select string_agg(coalesce(nullif(btrim(s2.web_name), ''), s2.name), ', ' order by s2.name) from __P__.staff s2
                   where s2.active and not s2.support and (s2.id = any(coalesce(k.coach_ids, '{}')) or s2.id = k.coach_id))) order by k.day, k.start_time)
      from __P__.classes k where not (k.off_from is not null and k.off_from <= today and (k.off_to is null or k.off_to >= today))), '[]'::jsonb),
    'packages', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', p.price_thb, 'was', p.was_thb, 'badge', p.badge, 'notes', p.notes,
        'days', p.duration_days, 'week', p.per_week_limit, 'visits', p.visit_limit, 'covers', p.covers, 'tiers', p.tiers) order by p.price_thb desc nulls last, p.name)
      from __P__.packages p where p.active and __Q__.can_buy(p.audience, 'standard') and (p.price_thb is not null or jsonb_array_length(coalesce(p.tiers, '[]'::jsonb)) > 0)
        and not (p.id::text in (select jsonb_array_elements_text(coalesce(s->'hide', '[]'::jsonb))))), '[]'::jsonb),
    'coaches', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(nullif(btrim(x.web_name), ''), x.name), 'title', x.web_title,
        'about', coalesce(nullif(btrim(x.web_about), ''), x.bio), 'photo', x.photo_url) order by x.web_sort nulls last, x.name)
      from __P__.staff x where x.active and x.web_show and not x.support), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403602, 4, 'patch', 'gym_site:403602', $TPL$create or replace function __P__.gym_web_trial(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare nm text := left(btrim(coalesce(p->>'name', '')), 80); em text := lower(left(btrim(coalesce(p->>'email', '')), 120));
  ph text := left(btrim(coalesce(p->>'phone', '')), 40); cl text := left(btrim(coalesce(p->>'class', '')), 120);
  msg text := left(btrim(coalesce(p->>'message', '')), 500); cid uuid; line text;
begin
  if not __Q__.feature('gym_site', false) or not __Q__.feature('gym_site_trial', true) then raise exception 'Free trials are not booked online here. Please get in touch.'; end if;
  if nm = '' then raise exception 'Please add your name.'; end if;
  if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'Please check your email address.'; end if;
  if (select count(*) from __P__.customers where lead_source = 'Website trial' and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many requests just now. Please try again later or get in touch.'; end if;
  line := to_char(now() at time zone __Q__.tz(), 'DD Mon YYYY HH24:MI') || ' free trial request from the website' || case when cl <> '' then ': ' || cl else '' end
    || case when msg <> '' then E'\n' || msg else '' end;
  select id into cid from __P__.customers where lower(email) = em order by created_at limit 1;
  if cid is null then
    insert into __P__.customers (name, email, phone, lead_source, tags, notes) values (nm, em, nullif(ph, ''), 'Website trial', array['Free trial'], line) returning id into cid;
  else
    update __P__.customers set notes = left(coalesce(nullif(notes, '') || E'\n', '') || line, 4000), phone = coalesce(phone, nullif(ph, '')),
      tags = case when 'Free trial' = any(tags) then tags else tags || 'Free trial' end where id = cid;
  end if;
  return jsonb_build_object('ok', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197601, 11, 'patch', 'gym_site:1197601', $TPL$revoke all on function __P__.gym_web() from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197602, 11, 'patch', 'gym_site:1197602', $TPL$revoke all on function __P__.gym_web_trial(jsonb) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197603, 11, 'patch', 'gym_site:1197603', $TPL$grant execute on function __P__.gym_web() to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197604, 11, 'patch', 'gym_site:1197604', $TPL$grant execute on function __P__.gym_web_trial(jsonb) to anon, authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'gym_site:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
