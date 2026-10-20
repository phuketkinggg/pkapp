-- Muay Friend demo database (project yojllgjjekitbktzblcc) ONLY. Never run on Phuket King.
-- private.demo_users(): makes the four demo logins once.
-- private.demo_reset(): wipes every public table and builds "Muay Fight Gym" again, dated around today.

create or replace function private.demo_users() returns void language plpgsql security definer set search_path='' as $f$
declare u record;
begin
  for u in select * from (values
    ('d0000000-0000-4000-8000-000000000001'::uuid,'owner@demo.muayfriend.com'),
    ('d0000000-0000-4000-8000-000000000002'::uuid,'desk@demo.muayfriend.com'),
    ('d0000000-0000-4000-8000-000000000003'::uuid,'coach@demo.muayfriend.com'),
    ('d0000000-0000-4000-8000-000000000004'::uuid,'member@demo.muayfriend.com')) v(id,email) loop
    if not exists (select 1 from auth.users where id=u.id) then
      insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,email_change,email_change_token_new,recovery_token)
      values ('00000000-0000-0000-0000-000000000000',u.id,'authenticated','authenticated',u.email,extensions.crypt('MuayFightDemo1',extensions.gen_salt('bf')),now(),
        '{"provider":"email","providers":["email"]}','{}',now(),now(),'','','','');
      insert into auth.identities(id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
      values (gen_random_uuid(),u.id,u.id::text,jsonb_build_object('sub',u.id::text,'email',u.email,'email_verified',true),'email',now(),now(),now());
    else
      update auth.users set encrypted_password=extensions.crypt('MuayFightDemo1',extensions.gen_salt('bf')), email=u.email, banned_until=null where id=u.id;
    end if;
  end loop;
end $f$;

create or replace function private.demo_reset() returns jsonb language plpgsql security definer set search_path='' as $f$
declare
  t date := (now() at time zone 'Asia/Bangkok')::date;
  nowt time := (now() at time zone 'Asia/Bangkok')::time;
  r record; i int; d date; k int; cid uuid; pid uuid; pk record; st date; ex date;
  s_owner uuid := 'd1000000-0000-4000-8000-000000000001'; s_desk uuid := 'd1000000-0000-4000-8000-000000000002';
  s_lek uuid := 'd1000000-0000-4000-8000-000000000003'; s_dam uuid := 'd1000000-0000-4000-8000-000000000004';
  s_nong uuid := 'd1000000-0000-4000-8000-000000000005'; s_boy uuid := 'd1000000-0000-4000-8000-000000000006';
  s_hk uuid := 'd1000000-0000-4000-8000-000000000007'; s_kit uuid := 'd1000000-0000-4000-8000-000000000008';
  c_member uuid := 'd2000000-0000-4000-8000-000000000001';
  coaches uuid[]; names text[]; countries text[]; tagsets text[][];
  cls record; room_ids uuid[] := '{}'; rid uuid; prog uuid; grp uuid; cat_d uuid; cat_f uuid; cat_g uuid; loc_desk uuid; loc_cafe uuid; ord uuid;
begin
  perform private.demo_users();
  -- wipe
  for r in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' loop
    execute format('truncate table public.%I cascade', r.relname);
  end loop;
  perform setseed(0.42);

  -- settings
  insert into public.app_settings(key,value) values
    ('checkin_code','MUAYFIGHT-DEMO'),
    ('review_message','Hi {name}, thanks so much for training with us at Muay Fight Gym! If you have a minute, a quick Google review helps us a lot: {link} See you in class.'),
    ('renew_message',''),
    ('prearrival','{"auto":false,"video_url":"","video_title":"Meet your coaches","groups":{}}'),
    ('kiosk_promos','[]'),('shop_vat','{"rate":0,"included":true}'),('app_theme','{"accent":"#2759DA"}');

  -- staff
  insert into public.staff(id,user_id,name,email,role,commission_pct,phone,active,work_days,work_start,work_end) values
    (s_owner,'d0000000-0000-4000-8000-000000000001','Alex (owner)','owner@demo.muayfriend.com','manager',0,null,true,null,null,null),
    (s_desk,'d0000000-0000-4000-8000-000000000002','Ploy (front desk)','desk@demo.muayfriend.com','front_desk',0,null,true,'{1,2,3,4,5,6}','07:30','15:30'),
    (s_lek,'d0000000-0000-4000-8000-000000000003','Kru Lek','coach@demo.muayfriend.com','coach',50,null,true,'{1,2,3,4,5,6}','07:30','19:00'),
    (s_dam,null,'Kru Dam',null,'coach',50,null,true,'{1,2,3,4,5}','07:30','19:00'),
    (s_nong,null,'Kru Nong',null,'coach',50,null,true,'{1,2,3,4,5,6}','15:00','20:00'),
    (s_boy,null,'Kru Boy',null,'coach',50,null,true,'{2,3,4,5,6}','07:30','19:00'),
    (s_hk,null,'Mali (housekeeping)',null,'housekeeping',0,null,true,'{1,2,3,4,5,6}','08:00','16:00'),
    (s_kit,null,'Noi (cafe)',null,'kitchen',0,null,true,'{1,2,3,4,5,6,7}','07:00','15:00');
  coaches := array[s_lek,s_dam,s_nong,s_boy];

  -- timetable (day 0 = Monday)
  for i in 0..5 loop
    insert into public.classes(day,start_time,title,discipline,coach_id) values
      (i,'08:00',case i when 0 then 'Morning class, kicks' when 1 then 'Morning class, punches' when 2 then 'Morning class, elbows' when 3 then 'Morning class, knees and teeps' when 4 then 'Morning class, defence' else 'Morning class, sparring technique' end,'Muay Thai',coaches[1+(i%4)]),
      (i,'16:30','Afternoon class','Muay Thai',coaches[1+((i+1)%4)]);
    if i<5 then insert into public.classes(day,start_time,title,discipline,coach_id) values (i,'18:30','Evening class','Muay Thai',coaches[1+((i+2)%4)]); end if;
    if i in (1,3) then insert into public.classes(day,start_time,title,discipline,coach_id) values (i,'18:00','Fight team clinch and sprints','Muay Thai',s_lek); end if;
    if i in (0,2,4) then insert into public.classes(day,start_time,title,discipline,coach_id) values (i,'09:45','Yoga and mobility','Yoga',null); end if;
  end loop;
  -- two coaches on each Muay Thai class (the class's own coach plus one more), end times on the main classes
  update public.classes k set coach_ids = array_remove(array[k.coach_id, case when k.coach_id = coaches[1] then coaches[2] else coaches[1] end], null),
    end_time = case to_char(k.start_time,'HH24:MI') when '08:00' then '09:30'::time when '16:30' then '18:00'::time when '18:30' then '20:00'::time when '18:00' then '19:00'::time when '09:45' then '10:45'::time end
  where k.discipline = 'Muay Thai';
  update public.classes set end_time = '10:45' where discipline = 'Yoga';

  -- packages
  insert into public.packages(slug,name,price_thb,price_local_thb,covers,visit_limit,duration_days,clock,qty_unit,notes,start_within_days) values
    ('drop-in','Drop in, 1 class',400,350,'{Muay Thai}',1,null,'first','visits',null,null),
    ('day-pass','Day pass',500,null,'{Muay Thai}',null,1,'first','visits',null,null),
    ('one-week','1 week unlimited',2500,null,'{Muay Thai}',null,7,'first','visits',null,null),
    ('ten-class','10 classes',3500,3000,'{Muay Thai}',10,180,'first','visits','Valid 6 months.',null),
    ('one-month','1 month unlimited',7000,3500,'{Muay Thai}',null,30,'first','visits',null,null),
    ('three-month','3 months unlimited',18000,9500,'{Muay Thai}',null,91,'first','visits',null,null),
    ('recovery-week','Training and recovery, 1 week',3900,null,'{Muay Thai,Spa}',null,7,'first','visits','Classes plus ice bath and sauna.',null),
    ('recovery-month','Training and recovery, 1 month',11000,7500,'{Muay Thai,Spa}',null,30,'first','visits',null,null),
    ('private-1','1 private',900,null,'{Privates}',1,90,'first','visits',null,90),
    ('private-5','Private, 5 pack',4000,null,'{Privates}',5,182,'purchase','visits','Valid 6 months.',null),
    ('private-10','Private, 10 pack',7500,7000,'{Privates}',10,182,'purchase','visits','Valid 6 months.',null),
    ('kids-month','Kids monthly',1800,null,'{Muay Thai,Kids}',null,30,'purchase','visits',null,null),
    ('dtv-6','DTV 6 months, 30 classes',24000,null,'{Muay Thai}',30,182,'first','visits','Includes DTV paperwork.',90),
    ('gym-month','Weights gym, 1 month',1800,null,'{Fitness zone,Open gym}',null,30,'first','visits',null,null),
    ('yoga-1','Yoga, 1 session',400,null,'{Yoga}',1,null,'first','visits',null,null);

  -- customers: 46 made up people
  names := array['Sam Carter','Emma Reid','Jake Morris','Sofia Lindqvist','Nattapong Kaewdee','Lucas Moreau','Mia Schneider','Oliver Brennan','Hannah Kim','Tomasz Nowak',
    'Chloe Dubois','Ryan O''Connell','Aiko Tanaka','Daniel Weber','Priya Shah','Marco Rossi','Isabella Costa','Ethan Walsh','Lena Fischer','Somchai Boonmee',
    'Grace Liu','Noah Jensen','Ava Thompson','Mateo Garcia','Sara Haddad','Leo Martin','Julia Novak','Ben Ashworth','Kanya Srisuk','Max Hoffmann',
    'Zoe Clarke','Arjun Mehta','Freya Olsen','Diego Alvarez','Nina Petrova','Tom Fletcher','Yuki Sato','Liam Byrne','Anna Kowalska','Chris Evans-Hill',
    'Maya Cohen','Pim Rattanakul','Elias Berg','Rosa Jimenez','Kai Mueller','Jess Taylor'];
  countries := array['United Kingdom','Australia','United Kingdom','Sweden','Thailand','France','Germany','Ireland','South Korea','Poland',
    'France','Ireland','Japan','Germany','India','Italy','Brazil','United Kingdom','Germany','Thailand',
    'China','Denmark','United States','Spain','Lebanon','France','Czechia','United Kingdom','Thailand','Germany',
    'United Kingdom','India','Norway','Argentina','Russia','Australia','Japan','Ireland','Poland','United States',
    'Israel','Thailand','Sweden','Mexico','Switzerland','Canada'];
  for i in 1..array_length(names,1) loop
    cid := case when i=1 then c_member else gen_random_uuid() end;
    insert into public.customers(id,user_id,name,email,phone,tier,price_group,country,tags,marketing_ok,lead_source,created_at,seen_at)
    values (cid, case when i=1 then 'd0000000-0000-4000-8000-000000000004'::uuid end, names[i],
      case when i=1 then 'member@demo.muayfriend.com' else lower(replace(replace(split_part(names[i],' ',1),'''',''),'-',''))||'.'||lower(replace(replace(split_part(names[i],' ',2),'''',''),'-',''))||'@example.com' end,
      case when countries[i]='Thailand' then '08'||(10000000+floor(random()*89999999))::bigint::text else '+44 7700 9'||(10000+floor(random()*89999))::int::text end,
      case when i in (1,5,20) then 'pangea' when i%7=0 then 'progress' else 'train' end,
      case when countries[i]='Thailand' then 'thai' when i%9=0 then 'local' else 'standard' end,
      countries[i],
      case when i in (1,5,20,29) then '{fighter}' when i%6=0 then '{dtv}' when i%5=0 then '{beginner}' when i%11=0 then '{kids parent}' else '{}' end::text[],
      true, case i%4 when 0 then 'Google' when 1 then 'Instagram' when 2 then 'Walk in' else 'Friend' end,
      now()-((60-i)||' days')::interval, now());
  end loop;

  -- packages bought: one active training package each, plus private packs for some
  for r in select c.id, (row_number() over (order by c.created_at))::int n from public.customers c loop
    select * into pk from public.packages where slug = case
      when r.n=1 then 'three-month' when r.n%9=0 then 'dtv-6' when r.n%7=0 then 'recovery-month' when r.n%5=0 then 'ten-class'
      when r.n%4=0 then 'one-week' when r.n%13=0 then 'kids-month' else 'one-month' end;
    st := t - ((r.n*3) % 26) - 1;
    ex := case when pk.duration_days is null then null else st + pk.duration_days end;
    insert into public.purchases(customer_id,package_id,package_name,price_thb,price_group,paid,method,purchased_on,covers,visit_limit,visits_left,duration_days,starts_on,expires_on,sold_by,paid_thb)
    values (r.id,pk.id,pk.name,pk.price_thb,'standard',r.n%17<>0,case r.n%3 when 0 then 'card' when 1 then 'cash' else 'transfer' end,st,pk.covers,pk.visit_limit,
      case when pk.visit_limit is null then null else greatest(1,pk.visit_limit-(r.n%8)-1) end,pk.duration_days,st,ex,s_desk,case when r.n%17<>0 then pk.price_thb else 0 end);
    if r.n in (1,3,6,8,12,15,21,26) then
      select * into pk from public.packages where slug = case when r.n%2=0 then 'private-5' else 'private-10' end;
      insert into public.purchases(customer_id,package_id,package_name,price_thb,price_group,paid,method,purchased_on,covers,visit_limit,visits_left,duration_days,starts_on,expires_on,sold_by,paid_thb)
      values (r.id,pk.id,pk.name,pk.price_thb,'standard',true,'card',st,pk.covers,pk.visit_limit,pk.visit_limit,pk.duration_days,st,st+pk.duration_days,s_desk,pk.price_thb);
    end if;
  end loop;

  -- check-ins for the last 3 weeks and today (only classes that already started today)
  for d in select generate_series(t-21, t, '1 day')::date loop
    for cls in select * from public.classes where day = extract(isodow from d)::int - 1 and discipline='Muay Thai' and (d<t or start_time <= nowt) loop
      k := 6 + floor(random()*10)::int;
      insert into public.checkins(customer_id,purchase_id,class_id,day,checked_in_at,checked_in_by,counted)
      select p.customer_id, p.id, cls.id, d, ((d + cls.start_time - interval '7 minutes') at time zone 'Asia/Bangkok') + (random()*interval '12 minutes'), s_desk, true
      from public.purchases p where 'Muay Thai'=any(p.covers) and p.starts_on<=d and (p.expires_on is null or p.expires_on>=d)
        and not exists (select 1 from public.checkins x where x.customer_id=p.customer_id and x.day=d)
      order by random() limit k;
    end loop;
  end loop;

  -- privates: past done, today, upcoming, two waiting for approval
  for i in 1..34 loop
    d := t + (i % 17) - 10;
    select p.id, p.customer_id into pid, cid from public.purchases p where 'Privates'=any(p.covers) order by random() limit 1;
    begin
      insert into public.privates(customer_id,coach_id,date,start_time,purchase_id,price_thb,coach_pct,status,paid,arrived_at,arrived_by,created_at)
      values (cid, coaches[1+(i%4)], d, (array['10:00','11:00','13:00','14:00','15:00','17:30'])[1+(i%6)]::time, pid, 800, 50,
        case when d<t then 'done' else 'confirmed' end, true,
        case when d<t then (d + time '10:00') at time zone 'Asia/Bangkok' end, case when d<t then 'desk' end, now()-interval '5 days');
    exception when others then null; -- skip a clash with the same coach and time
    end;
  end loop;
  insert into public.privates(customer_id,coach_id,date,start_time,price_thb,status,paid,notes,preferred_coach_id)
  select id, null, t+2, '16:00', 900, 'requested', false, 'First private, want to work on my kicks', s_lek from public.customers where name='Lucas Moreau';
  insert into public.privates(customer_id,coach_id,date,start_time,price_thb,status,paid,notes,preferred_coach_id)
  select id, null, t+3, '11:00', 900, 'requested', false, 'Can we do clinch work?', s_dam from public.customers where name='Hannah Kim';

  -- rooms and stays
  for i in 1..6 loop
    rid := gen_random_uuid(); room_ids := room_ids || rid;
    insert into public.rooms(id,name,sort,active) values (rid, case when i<=4 then 'Bungalow '||i else 'Garden room '||(i-4) end, i, true);
  end loop;
  insert into public.stays(customer_id,room_id,check_in,check_out,status,room_price_thb,training_included,notes)
  select c.id, room_ids[x.n], t + x.ci, t + x.co, x.s, x.price, true, null
  from (values (2,1,-5,9,'in',14000),(3,2,-2,5,'in',8400),(4,7,-12,2,'in',16800),(5,11,1,15,'booked',16800),(6,14,3,10,'booked',8400),(1,18,-20,-6,'out',16800)) x(n,cust,ci,co,s,price)
  join (select id, row_number() over (order by created_at) rn from public.customers) c on c.rn=x.cust;

  -- cafe and shop
  cat_d := gen_random_uuid(); cat_f := gen_random_uuid(); cat_g := gen_random_uuid(); loc_desk := gen_random_uuid(); loc_cafe := gen_random_uuid();
  insert into public.shop_categories(id,name,sort,active) values (cat_d,'Drinks',1,true),(cat_f,'Food',2,true),(cat_g,'Gear',3,true);
  insert into public.shop_locations(id,name,sort,active) values (loc_desk,'Front desk',1,true),(loc_cafe,'Cafe',2,true);
  insert into public.shop_products(name,category_id,price_thb,kitchen,in_app,active,sort,description) values
    ('Water',cat_d,20,false,true,true,1,null),('Coconut water',cat_d,60,false,true,true,2,null),('Iced latte',cat_d,90,true,true,true,3,null),
    ('Protein shake',cat_d,120,true,true,true,4,'Banana, oats, whey'),('Green smoothie',cat_d,110,true,true,true,5,null),
    ('Chicken rice bowl',cat_f,150,true,true,true,1,'Grilled chicken, rice, greens'),('Pad kra pao',cat_f,120,true,true,true,2,null),
    ('Overnight oats',cat_f,110,true,true,true,3,null),('Eggs on toast',cat_f,130,true,true,true,4,null),
    ('Hand wraps',cat_g,250,false,false,true,1,null),('Muay Fight shorts',cat_g,900,false,false,true,2,null),('Gloves 14oz',cat_g,1900,false,false,true,3,null);
  for i in 1..9 loop
    ord := gen_random_uuid();
    insert into public.shop_orders(id,created_at,created_by,source,customer_id,status,method,subtotal_thb,total_thb,kitchen_status,paid_at,location_id)
    select ord, now()-((i*40)||' minutes')::interval, s_desk, case when i%3=0 then 'app' else 'till' end, c.id,
      case when i<=2 then 'waiting' else 'paid' end, case when i<=2 then null else 'cash' end, 0, 0,
      case when i=1 then 'new' when i=2 then 'preparing' else 'done' end, case when i<=2 then null else now()-((i*40)||' minutes')::interval end, loc_cafe
    from public.customers c order by random() limit 1;
    insert into public.shop_order_items(order_id,product_id,name,price_thb,qty,kitchen)
    select ord, p.id, p.name, p.price_thb, 1+(i%2), p.kitchen from public.shop_products p where p.category_id in (cat_d,cat_f) order by random() limit 2;
    update public.shop_orders o set subtotal_thb=s.v, total_thb=s.v from (select sum(price_thb*qty) v from public.shop_order_items where order_id=ord) s where o.id=ord;
  end loop;

  -- coaching for the member login (Sam Carter): coach, goal, habits, weight, program, logs
  insert into public.coach_clients(customer_id,staff_id,added_by) values (c_member,s_lek,s_owner);
  insert into public.coach_goals(customer_id,kg,goal_on,note,updated_by) values (c_member,72,t+19,'Fight night at the stadium. Make 72 kg the day before.',s_lek);
  insert into public.habits(customer_id,name,details,freq,days,times,start_on,links,created_by) values
    (c_member,'Drink 3 litres of water','Carry a bottle to every class.','daily','{}',1,t-14,'[]',s_lek),
    (c_member,'10 minutes of stretching','After the evening class.','week','{}',4,t-10,'[]',s_lek),
    (c_member,'Shadow boxing, 3 rounds','Focus on the jab and the teep.','days','{1,3,5}',1,t-7,'[]',s_lek);
  insert into public.habit_logs(habit_id,day) select h.id, g::date from public.habits h, generate_series(t-13,t-1,'1 day') g where h.customer_id=c_member and h.freq='daily' and random()<0.8;
  insert into public.weights(customer_id,kg,at,note,by_staff) select c_member, round((78.6 - (g*0.32) + random()*0.4)::numeric,1), ((t-28+g*2) + time '07:30') at time zone 'Asia/Bangkok', '', null from generate_series(0,13) g;
  prog := gen_random_uuid();
  insert into public.programs(id,customer_id,name,notes,routines,created_by,visible_from) values (prog,c_member,'Fight camp strength','Four weeks before the fight. Keep it explosive, stay fresh for pads.',
    '[{"id":"r1","day":"1","name":"Monday: power","items":[{"id":"s1","kind":"section","name":"Warm up"},{"id":"e0","kind":"exercise","name":"Skipping","sets":"3","reps":"3 min","rest":"60","intensity":"Easy","notes":"","video":"","progressions":[],"step":0},{"id":"s2","kind":"section","name":"Power"},{"id":"e1","kind":"exercise","name":"Trap bar jump","sets":"4","reps":"5","rest":"120","intensity":"Fast","notes":"Land soft","video":"","progressions":["5 x 5"],"step":0,"ss":true},{"id":"e2","kind":"exercise","name":"Medicine ball rotational throw","sets":"4","reps":"6 each side","rest":"90","intensity":"Max speed","notes":"","video":"","progressions":[],"step":0,"sides":true},{"id":"e3","kind":"exercise","name":"Back squat","sets":"4","reps":"5","rest":"150","intensity":"RPE 7","notes":"Chest up","video":"","progressions":["4 x 4 at RPE 8"],"step":0}]},{"id":"r2","day":"4","name":"Thursday: strength","items":[{"id":"e4","kind":"exercise","name":"Single arm dumbbell press","sets":"3","reps":"8","rest":"90","intensity":"RPE 7","notes":"","video":"","progressions":[],"step":0,"sides":true},{"id":"e5","kind":"exercise","name":"Pull ups","sets":"4","reps":"6","rest":"90","intensity":"Bodyweight","notes":"","video":"","progressions":[],"step":0},{"id":"e6","kind":"exercise","name":"Neck bridge","sets":"3","reps":"30 sec","rest":"60","intensity":"Easy","notes":"","video":"","progressions":[],"step":0}]}]'::jsonb, s_lek, t-14);
  insert into public.exercise_logs(customer_id,program_id,routine_id,item_id,exercise_name,day,sets,sides,feel,hurt,note) values
    (c_member,prog,'r1','e3','Back squat',t-14,'[{"kg":70,"reps":5},{"kg":70,"reps":5},{"kg":72.5,"reps":5},{"kg":72.5,"reps":5}]',false,'good',false,''),
    (c_member,prog,'r1','e3','Back squat',t-7,'[{"kg":75,"reps":5},{"kg":75,"reps":5},{"kg":77.5,"reps":5},{"kg":77.5,"reps":4}]',false,'hard',false,'Last set was tough'),
    (c_member,prog,'r1','e3','Back squat',t,'[{"kg":77.5,"reps":5},{"kg":80,"reps":5},{"kg":80,"reps":5},{"kg":80,"reps":5}]',false,'good',false,'Felt strong');
  insert into public.workout_logs(program_id,routine_id,day,note) values (prog,'r1',t-14,''),(prog,'r1',t-7,''),(prog,'r2',t-4,'');

  -- an action group
  grp := gen_random_uuid();
  insert into public.action_groups(id,name,notes,items,created_by) values (grp,'Fight camp, 4 weeks','Everything for your first fight, week by week.',
    '[{"id":"a1","at_mode":"week","at_n":1,"kind":"video","title":"Welcome to fight camp","url":""},{"id":"a2","at_mode":"week","at_n":1,"kind":"weight","title":"First weigh in"},{"id":"a3","at_mode":"week","at_n":2,"kind":"food","title":"Start your food diary"}]'::jsonb, s_owner);
  insert into public.group_members(group_id,customer_id,start_on,added_by) values (grp,c_member,t-14,s_lek);

  -- get ready for camp: the member login has the form waiting, booked guests show under Arriving soon
  perform private.prearrival_seed();
  insert into public.prearrival(customer_id,arrival,sent_at,sent_to,expires_at) values (c_member,t+6,now()-interval '1 day','member@demo.muayfriend.com',now()+interval '30 days');
  insert into public.prearrival(customer_id,arrival,stay_id,sent_at,sent_to,opened_at,done_at,answers,expires_at)
  select x.customer_id, x.check_in, x.id, now()-interval '3 days', 'guest@example.com', case when x.rn=1 then now()-interval '2 days' end, case when x.rn=1 then now()-interval '2 days' end,
    case when x.rn=1 then '{"level":"new","goals":["technique","fitness"],"win":"Learn the basics properly and get fit","weight_kg":84,"target_kg":79,"height_cm":180,"fitness":2,"train_now":"1-2","injury":"yes","injury_where":"right shoulder","injury_note":"Old gym injury, fine most days","sessions":"2","privates":"maybe","food":"No pork"}'::jsonb else '{}'::jsonb end,
    now()+interval '30 days'
  from (select s.*, row_number() over (order by s.check_in) rn from public.stays s where s.status='booked') x;
  for r in select p.customer_id, p.arrival from public.prearrival p where p.done_at is not null loop
    insert into public.group_members(group_id,customer_id,start_on) values ((private.prearrival_cfg()->'groups'->>'beginner')::uuid, r.customer_id, r.arrival-14) returning id into grp;
    perform private.group_apply(grp);
    update public.prearrival set group_member=grp where customer_id=r.customer_id;
  end loop;

  -- fights
  insert into public.fights(fight_date,fight_time,venue,fighter_customer_id,fighter_name,weight,opponent,corner_ids,show_in_app,created_by)
  values (t+20,'20:00','City Stadium',c_member,'Sam Carter','72 kg','To be confirmed',array[s_lek,s_dam],true,s_owner);

  return jsonb_build_object('customers',(select count(*) from public.customers),'purchases',(select count(*) from public.purchases),
    'checkins',(select count(*) from public.checkins),'privates',(select count(*) from public.privates),'stays',(select count(*) from public.stays),
    'orders',(select count(*) from public.shop_orders),'payments',(select count(*) from public.payments));
end $f$;
revoke all on function private.demo_reset() from public, anon, authenticated;
revoke all on function private.demo_users() from public, anon, authenticated;
