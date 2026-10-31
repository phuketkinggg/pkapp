-- A simple website for a spa or salon (Massage Mate): Book, Prices and About, all from the app.
-- spa_web(): public info (name, colour, texts from app_settings spa_site, shops, treatments with prices, team on the website,
--   and the published pages made in Web pages: extra pages in the menu, or sections added to Book, Prices and About).
-- spa_web_times(): free start times for a treatment on a day. spa_web_book(): a booking made on the website.
-- Booking on the website is the feature switch web_booking (Settings, Features), off unless switched on. Needs the spa functions (spa_shops.sql):
-- on a database without them this file does nothing.
do $outer$
begin
  if to_regprocedure('private.spa_free_staff(uuid, date, time, uuid, uuid)') is null then
    raise notice 'spa_website: no spa functions here, skipped';
    return;
  end if;

  insert into public.app_settings(key, value) values ('spa_site', '{}') on conflict (key) do nothing;
  alter table public.privates add column if not exists web boolean not null default false;

  execute $f$
  create or replace function public.spa_web() returns jsonb language plpgsql stable security definer set search_path to '' as $$
  declare s jsonb; th jsonb; nm jsonb;
  begin
    begin s := (select value::jsonb from public.app_settings where key = 'spa_site'); exception when others then s := '{}'; end;
    begin th := (select value::jsonb from public.app_settings where key = 'app_theme'); exception when others then th := '{}'; end;
    begin nm := (select value::jsonb from public.app_settings where key = 'acc_names'); exception when others then nm := '{}'; end;
    return jsonb_build_object(
      'name', coalesce(nullif(s->>'name',''), nm->>'main', 'Our shop'),
      'accent', coalesce(th->>'accent', '#9C7A55'),
      'site', coalesce(s, '{}'::jsonb) - 'name',
      'booking', private.feature('web_booking', false),
      'shops', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort, name) from public.spa_shops), '[]'),
      'services', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'department', coalesce(department,''), 'minutes', minutes,
          'price', price_thb, 'text', coalesce(description,''), 'staff', coalesce(staff_ids, '{}'), 'shops', coalesce(shop_ids, '{}')) order by sort, name)
        from public.spa_services where active and price_thb > 0), '[]'),
      'team', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', coalesce(nullif(web_name,''), name), 'text', coalesce(nullif(web_about,''), bio, ''),
          'photo', photo_url) order by web_sort nulls last, name)
        from public.staff where active and role = 'coach'), '[]'),
      'pages', coalesce((select jsonb_agg(jsonb_build_object('slug', slug, 'title', title, 'description', coalesce(description,''), 'sections', coalesce(sections,'[]'::jsonb),
          'menu', coalesce(in_footer,false), 'label', coalesce(nullif(footer_label,''), title)) order by title)
        from public.site_pages where status = 'published' and not coalesce(removed,false)), '[]'));
  end $$;
  $f$;

  execute $f$
  create or replace function public.spa_web_times(p_service uuid, p_date date, p_staff uuid default null, p_shop uuid default null)
  returns jsonb language plpgsql stable security definer set search_path to '' as $$
  declare sv public.spa_services; t time := '09:00'; out jsonb := '[]'::jsonb; f uuid[]; nowt time := (now() at time zone 'Asia/Bangkok')::time; shop uuid;
  begin
    if not private.feature('web_booking', false) then return out; end if;
    if p_date is null or p_date < private.bkk_today() or p_date > private.bkk_today() + 60 then return out; end if;
    select * into sv from public.spa_services where id = p_service and active and price_thb > 0;
    if sv.id is null then return out; end if;
    shop := private.spa_pick_shop(sv.id, p_shop);
    while t <= time '22:00' - make_interval(mins => sv.minutes) loop
      if p_date > private.bkk_today() or t >= nowt + interval '30 minutes' then
        f := private.spa_free_staff(sv.id, p_date, t, null, shop);
        if p_staff is not null then f := array(select x from unnest(f) x where x = p_staff); end if;
        if cardinality(f) > 0 and private.spa_find_bed(sv.id, shop, p_date, t) is not null then out := out || to_jsonb(to_char(t, 'HH24:MI')); end if;
      end if;
      t := t + interval '15 minutes';
    end loop;
    return out;
  end $$;
  $f$;

  execute $f$
  create or replace function public.spa_web_book(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
  declare sv public.spa_services; d date; t time; cid uuid; who uuid; bed uuid; free uuid[]; v uuid; pct numeric; shop uuid;
    nm text := left(btrim(coalesce(p->>'name','')), 80); ph text := left(btrim(coalesce(p->>'phone','')), 30); em text := lower(left(btrim(coalesce(p->>'email','')), 120));
    digits text;
  begin
    if not private.feature('web_booking', false) then raise exception 'Online booking is closed. Please message us.'; end if;
    if char_length(nm) < 2 then raise exception 'Write your name.'; end if;
    digits := regexp_replace(ph, '\D', '', 'g');
    if char_length(digits) < 8 then raise exception 'Write your phone or WhatsApp number.'; end if;
    if em <> '' and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email does not look right.'; end if;
    select * into sv from public.spa_services where id = nullif(p->>'service_id','')::uuid and active and price_thb > 0;
    if sv.id is null then raise exception 'Choose a treatment.'; end if;
    shop := private.spa_pick_shop(sv.id, nullif(p->>'shop_id','')::uuid);
    begin d := (p->>'date')::date; t := (p->>'time')::time; exception when others then raise exception 'Choose a day and a time.'; end;
    if d is null or t is null then raise exception 'Choose a day and a time.'; end if;
    if d < private.bkk_today() or d > private.bkk_today() + 60 or (d = private.bkk_today() and t < (now() at time zone 'Asia/Bangkok')::time + interval '30 minutes') then
      raise exception 'Choose a time from now up to 60 days ahead.'; end if;
    -- no flooding: a few bookings per phone, and a cap on website bookings an hour
    if (select count(*) from public.privates x join public.customers c on c.id = x.customer_id
        where regexp_replace(coalesce(c.phone,''),'\D','','g') = digits and x.date >= private.bkk_today() and x.status <> 'cancelled') >= 4 then
      raise exception 'You already have bookings with us. Message us to add more.'; end if;
    if (select count(*) from public.privates where web and created_at > now() - interval '1 hour') >= 30 then
      raise exception 'Too many bookings just now. Please try again soon or message us.'; end if;
    select id into cid from public.customers where regexp_replace(coalesce(phone,''),'\D','','g') = digits limit 1;
    if cid is null and em <> '' then select id into cid from public.customers where lower(email) = em limit 1; end if;
    if cid is null then
      insert into public.customers (name, phone, email, lead_source) values (nm, ph, nullif(em,''), 'Website') returning id into cid;
    end if;
    free := private.spa_free_staff(sv.id, d, t, null, shop);
    who := nullif(p->>'staff_id','')::uuid;
    if who is not null and not (who = any(free)) then raise exception 'That person is not free then. Choose another time or anyone.'; end if;
    if who is null then who := private.spa_next_staff(free, d); end if;
    if who is null then raise exception 'That time has just gone. Choose another.'; end if;
    bed := private.spa_find_bed(sv.id, shop, d, t);
    if bed is null then raise exception 'That time has just gone. Choose another.'; end if;
    select coalesce(commission_pct, 50) into pct from public.staff where id = who;
    insert into public.privates (customer_id, coach_id, date, start_time, minutes, price_thb, coach_pct, status, paid, notes, any_coach, service_id, bed_id, shop_id, walk_in, web)
      values (cid, who, d, t, sv.minutes, sv.price_thb, pct, 'confirmed', false,
        nullif(left(btrim(coalesce(p->>'note','')), 300), ''), nullif(p->>'staff_id','') is null, sv.id, bed, shop, false, true)
      returning id into v;
    return jsonb_build_object('id', v, 'service', sv.name, 'date', d, 'time', to_char(t,'HH24:MI'), 'minutes', sv.minutes, 'price', sv.price_thb,
      'staff', (select coalesce(nullif(web_name,''), name) from public.staff where id = who), 'shop', (select name from public.spa_shops where id = shop));
  end $$;
  $f$;

  revoke all on function public.spa_web() from public;
  revoke all on function public.spa_web_times(uuid, date, uuid, uuid) from public;
  revoke all on function public.spa_web_book(jsonb) from public;
  grant execute on function public.spa_web() to anon, authenticated;
  grant execute on function public.spa_web_times(uuid, date, uuid, uuid) to anon, authenticated;
  grant execute on function public.spa_web_book(jsonb) to anon, authenticated;
end $outer$;
