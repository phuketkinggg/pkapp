-- Massage Mate demo database (project phjekupadmjwzrocahiv) ONLY. Never run on Phuket King or Muay Friend.
-- private.mm_demo_users(): the four demo logins.  private.mm_demo_reset(): wipes and builds "Massage Mate Demo Spa" around today.

create or replace function private.mm_demo_users() returns void language plpgsql security definer set search_path='' as $f$
declare u record;
begin
  for u in select * from (values
    ('e0000000-0000-4000-8000-000000000001'::uuid,'owner@demo.massagemate.app'),
    ('e0000000-0000-4000-8000-000000000002'::uuid,'desk@demo.massagemate.app'),
    ('e0000000-0000-4000-8000-000000000003'::uuid,'therapist@demo.massagemate.app'),
    ('e0000000-0000-4000-8000-000000000004'::uuid,'guest@demo.massagemate.app')) v(id,email) loop
    if not exists (select 1 from auth.users where id=u.id) then
      insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,email_change,email_change_token_new,recovery_token)
      values ('00000000-0000-0000-0000-000000000000',u.id,'authenticated','authenticated',u.email,extensions.crypt('MassageMateDemo1',extensions.gen_salt('bf')),now(),
        '{"provider":"email","providers":["email"]}','{}',now(),now(),'','','','');
      insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
      values (gen_random_uuid(),u.id,u.id::text,jsonb_build_object('sub',u.id::text,'email',u.email,'email_verified',true),'email',now(),now(),now());
    else
      update auth.users set encrypted_password=extensions.crypt('MassageMateDemo1',extensions.gen_salt('bf')), email=u.email, banned_until=null where id=u.id;
    end if;
  end loop;
end $f$;

create or replace function private.mm_demo_reset() returns jsonb language plpgsql security definer set search_path='' as $f$
declare
  t date := (now() at time zone 'Asia/Bangkok')::date;
  nowt time := (now() at time zone 'Asia/Bangkok')::time;
  r record; i int; d date; cid uuid; sv record; tm time; who uuid; bed uuid; n int; free uuid[];
  s_owner uuid := 'e1000000-0000-4000-8000-000000000001'; s_desk uuid := 'e1000000-0000-4000-8000-000000000002';
  s_ploy uuid := 'e1000000-0000-4000-8000-000000000003'; s_noi uuid := 'e1000000-0000-4000-8000-000000000004';
  s_joy uuid := 'e1000000-0000-4000-8000-000000000005'; s_mai uuid := 'e1000000-0000-4000-8000-000000000006';
  s_lek uuid := 'e1000000-0000-4000-8000-000000000007'; s_bee uuid := 'e1000000-0000-4000-8000-000000000008';
  s_kanya uuid := 'e1000000-0000-4000-8000-000000000009';
  c_guest uuid := 'e2000000-0000-4000-8000-000000000001';
  massage uuid[]; names text[]; countries text[]; cat_o uuid; cat_d uuid; loc_desk uuid; ord uuid;
  slots time[] := array['10:00','10:30','11:00','11:30','12:00','13:00','13:30','14:00','14:30','15:00','15:30','16:00','16:30','17:00','17:30','18:00','18:30','19:00','19:30','20:00','20:30']::time[];
begin
  perform private.mm_demo_users();
  for r in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' loop
    execute format('truncate table public.%I cascade', r.relname);
  end loop;
  perform setseed(0.37);

  insert into public.app_settings(key,value) values
    ('checkin_code','MASSAGEMATE-DEMO'),
    ('review_message','Hi {name}, thank you for visiting Massage Mate Demo Spa! If you enjoyed your treatment, a quick Google review helps us a lot: {link}'),
    ('renew_message',''), ('kiosk_promos','[]'), ('shop_vat','{"rate":0,"included":true}'), ('app_theme','{"accent":"#2E8B7A"}');

  insert into public.staff(id,user_id,name,email,role,commission_pct,phone,active,work_days,work_start,work_end,bio) values
    (s_owner,'e0000000-0000-4000-8000-000000000001','Nina (owner)','owner@demo.massagemate.app','manager',0,null,true,null,null,null,null),
    (s_desk,'e0000000-0000-4000-8000-000000000002','Fon (front desk)','desk@demo.massagemate.app','front_desk',0,null,true,'{0,1,2,3,4,5,6}','10:00','22:00',null),
    (s_ploy,'e0000000-0000-4000-8000-000000000003','Ploy','therapist@demo.massagemate.app','coach',45,null,true,'{0,1,2,3,4,5,6}','10:00','22:00','Thai and oil massage, 12 years'),
    (s_noi,null,'Noi',null,'coach',45,null,true,'{0,1,2,3,4,5}','10:00','22:00','Thai massage and foot reflexology'),
    (s_joy,null,'Joy',null,'coach',45,null,true,'{1,2,3,4,5,6}','10:00','22:00','Oil and aroma massage'),
    (s_mai,null,'Mai',null,'coach',40,null,true,'{0,2,3,4,5,6}','12:00','22:00','Thai massage, strong pressure'),
    (s_lek,null,'Lek',null,'coach',40,null,true,'{0,1,3,4,5,6}','10:00','20:00','Foot and head massage'),
    (s_bee,null,'Bee',null,'coach',50,null,true,'{0,1,2,3,4,5,6}','10:00','20:00','Nails: gel, art, pedicure'),
    (s_kanya,null,'Kanya',null,'coach',50,null,true,'{0,1,2,4,5,6}','11:00','20:00','Facials and skin care');
  massage := array[s_ploy,s_noi,s_joy,s_mai,s_lek];

  insert into public.spa_beds(name,kind,department,sort) values
    ('Bed 1','bed','Massage',1),('Bed 2','bed','Massage',2),('Bed 3','bed','Massage',3),('Bed 4','bed','Massage',4),
    ('Couple room','couple','Massage',5),('Foot chair 1','foot','Massage',6),('Foot chair 2','foot','Massage',7),
    ('Nail desk 1','nail','Nails',8),('Nail desk 2','nail','Nails',9),('Facial room','facial','Beauty',10);

  insert into public.spa_services(name,department,minutes,price_thb,bed_kind,staff_ids,description,sort) values
    ('Thai massage, 60 minutes','Massage',60,400,'bed',massage,'Traditional stretching and pressure, no oil.',1),
    ('Thai massage, 90 minutes','Massage',90,550,'bed',massage,null,2),
    ('Thai massage, 120 minutes','Massage',120,700,'bed',massage,null,3),
    ('Oil massage, 60 minutes','Massage',60,500,'bed',array[s_ploy,s_joy,s_mai],'Relaxing full body massage with warm oil.',4),
    ('Oil massage, 90 minutes','Massage',90,700,'bed',array[s_ploy,s_joy,s_mai],null,5),
    ('Aroma massage, 60 minutes','Massage',60,700,'bed',array[s_joy,s_ploy],'Essential oils of your choice.',6),
    ('Couple Thai massage, 60 minutes','Massage',60,400,'couple',massage,'Price per person. Book one for each guest.',7),
    ('Foot massage, 30 minutes','Massage',30,250,'foot',array[s_noi,s_lek,s_mai],null,8),
    ('Foot massage, 60 minutes','Massage',60,350,'foot',array[s_noi,s_lek,s_mai],'Reflexology on the feet and lower legs.',9),
    ('Head, neck and shoulders, 30 minutes','Massage',30,250,'bed',massage,null,10),
    ('Manicure','Nails',45,300,'nail',array[s_bee],null,11),
    ('Pedicure','Nails',60,400,'nail',array[s_bee],null,12),
    ('Gel nails, hands','Nails',90,700,'nail',array[s_bee],'Includes shaping and cuticle care.',13),
    ('Classic facial','Beauty',60,900,'facial',array[s_kanya],'Cleanse, scrub, mask and massage.',14),
    ('Brightening facial','Beauty',75,1300,'facial',array[s_kanya],null,15);

  names := array['Sophie Turner','Liam Walsh','Anna Becker','Kenji Mori','Isla Brown','Lucas Silva','Mila Novak','Oscar Lind','Chloe Martin','Ravi Patel',
    'Emma Jansen','Noah Fischer','Hana Kim','Ella Rossi','Jack Murphy','Sara Nilsson','Ben Cohen','Julia Weber','Tom Hughes','Aya Suzuki',
    'Nok Siriwan','Paul Dubois','Grace Lee','Felix Wagner','Maya Singh','Leo Costa','Olivia Smith','Daniel Park','Ruby Evans','Max Larsen',
    'Somsri Chaiyo','Ivan Petrov','Lily Chen','Adam Novak','Zara Ali','Finn Kelly','Nora Haug','Eric Blom','Ploy Thongdee','Ines Garcia'];
  countries := array['United Kingdom','Ireland','Germany','Japan','Australia','Brazil','Czechia','Sweden','France','India',
    'Netherlands','Germany','South Korea','Italy','Ireland','Sweden','Israel','Germany','United Kingdom','Japan',
    'Thailand','France','Singapore','Austria','India','Portugal','United States','South Korea','United Kingdom','Denmark',
    'Thailand','Russia','China','Poland','United Arab Emirates','Ireland','Norway','Sweden','Thailand','Spain'];
  for i in 1..array_length(names,1) loop
    cid := case when i=1 then c_guest else gen_random_uuid() end;
    insert into public.customers(id,user_id,name,email,phone,tier,price_group,country,tags,marketing_ok,lead_source,created_at,seen_at)
    values (cid, case when i=1 then 'e0000000-0000-4000-8000-000000000004'::uuid end, names[i],
      case when i=1 then 'guest@demo.massagemate.app' else lower(split_part(names[i],' ',1))||'.'||lower(split_part(names[i],' ',2))||'@example.com' end,
      case when countries[i]='Thailand' then '08'||(10000000+floor(random()*89999999))::bigint::text else '+44 7700 9'||(10000+floor(random()*89999))::int::text end,
      'train', case when countries[i]='Thailand' then 'thai' else 'standard' end, countries[i],
      case when i%5=0 then '{regular}' when i%7=0 then '{hotel guest}' else '{}' end::text[], true,
      case i%4 when 0 then 'Google' when 1 then 'Walk in' when 2 then 'Hotel' else 'Instagram' end,
      now()-((45-i)||' days')::interval, now());
  end loop;

  -- appointments: the last 14 days (done and paid), today (done before now, in progress, coming up) and the next 3 days
  for d in select generate_series(t-14, t+3, '1 day')::date loop
    n := case when d < t then 14 + floor(random()*8)::int when d = t then 18 else 6 + floor(random()*5)::int end;
    for i in 1..n loop
      select * into sv from public.spa_services order by random() limit 1;
      select id into cid from public.customers order by random() limit 1;
      tm := slots[1 + floor(random()*array_length(slots,1))::int];
      free := private.spa_free_staff(sv.id, d, tm, null);
      if cardinality(free) = 0 then continue; end if;
      who := free[1 + floor(random()*cardinality(free))::int];
      select b.id into bed from public.spa_beds b where b.kind = sv.bed_kind and private.spa_bed_free(b.id, d, tm, sv.minutes) order by b.sort limit 1;
      if bed is null then continue; end if;
      begin
        insert into public.privates(customer_id,coach_id,date,start_time,minutes,price_thb,coach_pct,status,paid,method,service_id,bed_id,walk_in,any_coach,arrived_at,arrived_by,created_at)
        values (cid, who, d, tm, sv.minutes, sv.price_thb, (select coalesce(commission_pct,45) from public.staff where id=who),
          case when d < t or (d = t and tm + make_interval(mins => sv.minutes) <= nowt) then 'done' else 'confirmed' end,
          d < t or (d = t and tm + make_interval(mins => sv.minutes) <= nowt),
          case when d < t or (d = t and tm + make_interval(mins => sv.minutes) <= nowt) then (array['cash','cash','card','transfer'])[1+floor(random()*4)::int] end,
          sv.id, bed, random() < 0.45, random() < 0.8,
          case when d < t or (d = t and tm <= nowt) then ((d + tm) at time zone 'Asia/Bangkok') end, case when d < t or (d = t and tm <= nowt) then 'spa' end,
          now() - interval '2 days');
      exception when others then null;
      end;
    end loop;
  end loop;

  -- the guest login has an appointment tomorrow
  select * into sv from public.spa_services where name = 'Oil massage, 90 minutes';
  free := private.spa_free_staff(sv.id, t+1, '15:00', null);
  if cardinality(free) > 0 then
    select b.id into bed from public.spa_beds b where b.kind='bed' and private.spa_bed_free(b.id, t+1, '15:00', sv.minutes) order by b.sort limit 1;
    if bed is not null then
      insert into public.privates(customer_id,coach_id,date,start_time,minutes,price_thb,coach_pct,status,paid,service_id,bed_id,any_coach,notes)
      values (c_guest, free[1], t+1, '15:00', sv.minutes, sv.price_thb, 45, 'confirmed', false, sv.id, bed, true, 'Medium pressure, sore shoulders');
    end if;
  end if;

  -- shop: oils, balms, drinks
  cat_o := gen_random_uuid(); cat_d := gen_random_uuid(); loc_desk := gen_random_uuid();
  insert into public.shop_categories(id,name,sort,active) values (cat_o,'Oils and balms',1,true),(cat_d,'Drinks',2,true);
  insert into public.shop_locations(id,name,sort,active) values (loc_desk,'Front desk',1,true);
  insert into public.shop_products(name,category_id,price_thb,kitchen,in_app,active,sort,description) values
    ('Lemongrass massage oil',cat_o,290,false,true,true,1,'100 ml'),('Thai herbal balm',cat_o,150,false,true,true,2,null),
    ('Coconut body lotion',cat_o,350,false,true,true,3,null),('Herbal compress ball',cat_o,180,false,true,true,4,null),
    ('Ginger tea',cat_d,60,false,true,true,1,null),('Coconut water',cat_d,70,false,true,true,2,null),('Water',cat_d,20,false,true,true,3,null);
  for i in 1..8 loop
    ord := gen_random_uuid();
    insert into public.shop_orders(id,created_at,created_by,source,customer_id,status,method,subtotal_thb,total_thb,paid_at,location_id)
    select ord, now()-((i*55)||' minutes')::interval, s_desk, 'till', c.id, 'paid', 'cash', 0, 0, now()-((i*55)||' minutes')::interval, loc_desk
    from public.customers c order by random() limit 1;
    insert into public.shop_order_items(order_id,product_id,name,price_thb,qty,kitchen)
    select ord, p.id, p.name, p.price_thb, 1, false from public.shop_products p order by random() limit 1+(i%2);
    update public.shop_orders o set subtotal_thb=s.v, total_thb=s.v from (select sum(price_thb*qty) v from public.shop_order_items where order_id=ord) s where o.id=ord;
  end loop;

  return jsonb_build_object('customers',(select count(*) from public.customers),'appointments',(select count(*) from public.privates),
    'today',(select count(*) from public.privates where date=t),'payments',(select count(*) from public.payments));
end $f$;
revoke all on function private.mm_demo_reset() from public, anon, authenticated;
revoke all on function private.mm_demo_users() from public, anon, authenticated;

-- Personalised demo: "Divine Diva" (three shops, two buildings, a treatment menu per shop, commission levels #1 to #5).
-- Prices, times and staff names are examples until the owner sends the real ones.
create table if not exists private.mm_demo_profile (id int primary key default 1 check (id = 1), profile text not null default 'generic');
insert into private.mm_demo_profile (id, profile) values (1, 'generic') on conflict (id) do nothing;

create or replace function private.mm_demo_divine() returns jsonb language plpgsql security definer set search_path='' as $f$
declare
  t date := (now() at time zone 'Asia/Bangkok')::date; nowt time := (now() at time zone 'Asia/Bangkok')::time;
  r record; i int; d date; cid uuid; sv record; tm time; who uuid; bed uuid; n int; free uuid[]; shop uuid; done_ boolean;
  sh_kathu uuid := 'e3000000-0000-4000-8000-000000000001'; sh_thai uuid := 'e3000000-0000-4000-8000-000000000002'; sh_chalong uuid := 'e3000000-0000-4000-8000-000000000003';
  s_owner uuid := 'e1000000-0000-4000-8000-000000000001'; s_desk uuid := 'e1000000-0000-4000-8000-000000000002';
  names text[]; countries text[];
  slots time[] := array['10:00','10:30','11:00','11:30','12:00','13:00','13:30','14:00','14:30','15:00','15:30','16:00','16:30','17:00','17:30','18:00','18:30','19:00','19:30']::time[];
begin
  perform private.mm_demo_users();
  for r in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' loop
    execute format('truncate table public.%I cascade', r.relname);
  end loop;
  perform setseed(0.21);
  insert into public.app_settings(key,value) values
    ('checkin_code','DIVINE-DEMO'), ('review_message','Hi {name}, thank you for visiting Divine Diva! If you enjoyed your treatment, a quick Google review helps us a lot: {link}'),
    ('renew_message',''), ('kiosk_promos','[]'), ('shop_vat','{"rate":0,"included":true}'), ('app_theme','{"accent":"#B5577B"}'),
    ('spa_levels','[{"level":1,"name":"#1","pct":30},{"level":2,"name":"#2","pct":35},{"level":3,"name":"#3","pct":40},{"level":4,"name":"#4","pct":45},{"level":5,"name":"#5","pct":50}]');

  insert into public.spa_shops(id,name,sort) values (sh_kathu,'Divine Diva Kathu',1),(sh_thai,'Divine Thai Spa',2),(sh_chalong,'Divine Diva Chalong',3);

  insert into public.staff(id,user_id,name,email,role,commission_pct,active,work_days,work_start,work_end,shop_ids,pay_level,bio) values
    (s_owner,'e0000000-0000-4000-8000-000000000001','Owner','owner@demo.massagemate.app','manager',0,true,null,null,null,'{}',null,null),
    (s_desk,'e0000000-0000-4000-8000-000000000002','Front desk','desk@demo.massagemate.app','front_desk',0,true,'{0,1,2,3,4,5,6}','10:00','21:00','{}',null,null),
    ('e1000000-0000-4000-8000-000000000003','e0000000-0000-4000-8000-000000000003','Pim','therapist@demo.massagemate.app','coach',35,true,'{0,1,2,3,4,5,6}','10:00','20:00',array[sh_thai],2,'Thai and oil massage'),
    ('e1000000-0000-4000-8000-000000000004',null,'Nok',null,'coach',30,true,'{0,1,2,3,4,5}','10:00','20:00',array[sh_thai],1,null),
    ('e1000000-0000-4000-8000-000000000005',null,'Lek',null,'coach',40,true,'{1,2,3,4,5,6}','10:00','20:00',array[sh_thai],3,null),
    ('e1000000-0000-4000-8000-000000000006',null,'Fah',null,'coach',30,true,'{0,2,3,4,5,6}','12:00','20:00',array[sh_thai],1,null),
    ('e1000000-0000-4000-8000-000000000007',null,'Mint',null,'coach',50,true,'{0,1,2,3,4,5}','10:00','20:00',array[sh_kathu],5,'Facials and lymphatic drainage'),
    ('e1000000-0000-4000-8000-000000000008',null,'Ploy',null,'coach',45,true,'{1,2,3,4,5,6}','10:00','20:00',array[sh_kathu],4,null),
    ('e1000000-0000-4000-8000-000000000009',null,'Jane',null,'coach',40,true,'{0,1,3,4,5,6}','10:00','20:00',array[sh_kathu],3,null),
    ('e1000000-0000-4000-8000-000000000010',null,'Nida',null,'coach',45,true,'{0,1,2,3,4,5}','10:00','20:00',array[sh_chalong],4,null),
    ('e1000000-0000-4000-8000-000000000011',null,'Ann',null,'coach',35,true,'{1,2,3,4,5,6}','10:00','20:00',array[sh_chalong],2,null);

  insert into public.spa_beds(name,building,kind,department,shop_ids,sort) values
    ('Room 1','Thai Spa Building','bed','Massage',array[sh_thai],1),('Room 2','Thai Spa Building','bed','Massage',array[sh_thai],2),
    ('Room 3','Thai Spa Building','bed','Massage',array[sh_thai],3),('Room 4','Thai Spa Building','bed','Massage',array[sh_thai],4),
    ('Room 1','Solea Building','bed','Massage',array[sh_kathu],5),('Room 2','Solea Building','bed','Massage',array[sh_kathu],6),
    ('Room 3','Solea Building','bed','Massage',array[sh_kathu],7),('Room 4','Solea Building','bed','Massage',array[sh_kathu],8),
    ('Room 1','Chalong (example)','bed','Massage',array[sh_chalong],9),('Room 2','Chalong (example)','bed','Massage',array[sh_chalong],10);

  insert into public.spa_services(name,department,minutes,price_thb,bed_kind,shop_ids,sort) values
    ('Thai Massage','Massage',60,400,'bed',array[sh_thai],1),
    ('Oil Massage','Massage',60,500,'bed',array[sh_thai],2),
    ('Foot Massage','Massage',60,350,'bed',array[sh_thai],3),
    ('Head and Shoulders Massage','Massage',30,300,'bed',array[sh_thai],4),
    ('Lymphatic Body Massage','Massage',90,1200,'bed',array[sh_thai],5),
    ('Gentleman''s Glow','Facial',60,1500,'bed',array[sh_kathu,sh_chalong],10),
    ('Lymphatic Drainage Body Massage','Body',90,1800,'bed',array[sh_kathu,sh_chalong],11),
    ('Lymphatic Drainage for face and body','Body',120,2500,'bed',array[sh_kathu,sh_chalong],12),
    ('Facial and Body Hangover Relief','Body',90,1900,'bed',array[sh_kathu,sh_chalong],13),
    ('Facial Massage Office Syndrome','Facial',60,1200,'bed',array[sh_kathu,sh_chalong],14),
    ('Facial Massage Migraines','Facial',60,1200,'bed',array[sh_kathu,sh_chalong],15),
    ('Facial Massage and Detoxify','Facial',60,1300,'bed',array[sh_kathu,sh_chalong],16),
    ('Gua Sha Facial Massage','Facial',60,1300,'bed',array[sh_kathu,sh_chalong],17),
    ('Full Facial Massage Course','Facial',90,1800,'bed',array[sh_kathu,sh_chalong],18),
    ('Hydra Facials Treatment','Facial',75,2500,'bed',array[sh_kathu,sh_chalong],19),
    ('Facial Massage Treatment','Facial',60,1100,'bed',array[sh_kathu,sh_chalong],20),
    ('Head Massage','Massage',30,600,'bed',array[sh_kathu,sh_chalong],21),
    ('Divine Detox Back Spa','Body',60,1400,'bed',array[sh_kathu,sh_chalong],22),
    ('Sensitive Skin Soothe','Facial',60,1500,'bed',array[sh_kathu,sh_chalong],23),
    ('Acne Rescue','Facial',60,1500,'bed',array[sh_kathu,sh_chalong],24),
    ('Firm and Flow Cellulite','Body',75,1900,'bed',array[sh_kathu,sh_chalong],25);

  names := array['Sophie Turner','Liam Walsh','Anna Becker','Kenji Mori','Isla Brown','Lucas Silva','Mila Novak','Oscar Lind','Chloe Martin','Ravi Patel',
    'Emma Jansen','Noah Fischer','Hana Kim','Ella Rossi','Jack Murphy','Sara Nilsson','Ben Cohen','Julia Weber','Tom Hughes','Aya Suzuki',
    'Nok Siriwan','Paul Dubois','Grace Lee','Felix Wagner','Maya Singh','Leo Costa','Olivia Smith','Daniel Park','Ruby Evans','Max Larsen'];
  countries := array['United Kingdom','Ireland','Germany','Japan','Australia','Brazil','Czechia','Sweden','France','India',
    'Netherlands','Germany','South Korea','Italy','Ireland','Sweden','Israel','Germany','United Kingdom','Japan',
    'Thailand','France','Singapore','Austria','India','Portugal','United States','South Korea','United Kingdom','Denmark'];
  for i in 1..array_length(names,1) loop
    cid := case when i=1 then 'e2000000-0000-4000-8000-000000000001'::uuid else gen_random_uuid() end;
    insert into public.customers(id,user_id,name,email,phone,tier,price_group,country,tags,marketing_ok,lead_source,created_at,seen_at)
    values (cid, case when i=1 then 'e0000000-0000-4000-8000-000000000004'::uuid end, names[i],
      case when i=1 then 'guest@demo.massagemate.app' else lower(split_part(names[i],' ',1))||'.'||lower(split_part(names[i],' ',2))||'@example.com' end,
      case when countries[i]='Thailand' then '08'||(10000000+floor(random()*89999999))::bigint::text else '+44 7700 9'||(10000+floor(random()*89999))::int::text end,
      'train', case when countries[i]='Thailand' then 'thai' else 'standard' end, countries[i], '{}', true,
      case i%4 when 0 then 'Google' when 1 then 'Walk in' when 2 then 'Hotel' else 'Instagram' end, now()-((40-i)||' days')::interval, now());
  end loop;

  for d in select generate_series(t-14, t+3, '1 day')::date loop
    n := case when d < t then 16 + floor(random()*8)::int when d = t then 20 else 7 + floor(random()*5)::int end;
    for i in 1..n loop
      select * into sv from public.spa_services order by random() limit 1;
      shop := sv.shop_ids[1 + floor(random()*cardinality(sv.shop_ids))::int];
      select id into cid from public.customers order by random() limit 1;
      tm := slots[1 + floor(random()*array_length(slots,1))::int];
      free := private.spa_free_staff(sv.id, d, tm, null, shop);
      if cardinality(free) = 0 then continue; end if;
      who := free[1 + floor(random()*cardinality(free))::int];
      bed := private.spa_find_bed(sv.id, shop, d, tm);
      if bed is null then continue; end if;
      done_ := d < t or (d = t and tm + make_interval(mins => sv.minutes) <= nowt);
      begin
        insert into public.privates(customer_id,coach_id,date,start_time,minutes,price_thb,coach_pct,status,paid,method,service_id,bed_id,shop_id,walk_in,any_coach,arrived_at,arrived_by,created_at)
        values (cid, who, d, tm, sv.minutes, sv.price_thb, (select coalesce(commission_pct,40) from public.staff where id=who),
          case when done_ then 'done' else 'confirmed' end, done_, case when done_ then (array['cash','card','card','transfer'])[1+floor(random()*4)::int] end,
          sv.id, bed, shop, random() < 0.35, random() < 0.75,
          case when d < t or (d = t and tm <= nowt) then ((d + tm) at time zone 'Asia/Bangkok') end, case when d < t or (d = t and tm <= nowt) then 'spa' end, now() - interval '2 days');
      exception when others then null;
      end;
    end loop;
  end loop;
  return jsonb_build_object('profile','divine','appointments',(select count(*) from public.privates),'today',(select count(*) from public.privates where date=t));
end $f$;
revoke all on function private.mm_demo_divine() from public, anon, authenticated;

-- the nightly reset rebuilds whichever demo is chosen: update private.mm_demo_profile set profile = 'divine' (or 'generic')
create or replace function private.mm_demo_run() returns jsonb language plpgsql security definer set search_path='' as $f$
begin
  if (select profile from private.mm_demo_profile where id = 1) = 'divine' then return private.mm_demo_divine(); end if;
  return private.mm_demo_reset();
end $f$;
revoke all on function private.mm_demo_run() from public, anon, authenticated;
