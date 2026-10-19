-- The three "Get ready" countdown groups. Day 1 is 14 days before arrival, day 15 is arrival day.
-- Only added when missing; coaches can change them any time in Coaching, Action groups.
create or replace function private.prearrival_seed() returns void language plpgsql security definer set search_path='' as $f$
declare cfg jsonb; gb uuid; ge uuid; gf uuid;
  common_end jsonb := '[
    {"id":"pa-bring","kind":"note","at_mode":"day","at_n":11,"title":"What to bring","text":"- Light training clothes, two or three sets (you will sweat a lot)\n- Hand wraps, gloves and shin guards if you have them. If not, message us and we will help\n- A water bottle\n- Flip flops and a towel for after training\n- Any medicine you need"},
    {"id":"pa-first","kind":"note","at_mode":"day","at_n":13,"title":"Your first day","text":"Come to the front desk before your first class and we will check you in. Group classes run Monday to Saturday, the full timetable is in the app.\n\nWant a head start? Book a private with one of the coaches for your first week, in the app under Privates."},
    {"id":"pa-here","kind":"note","at_mode":"day","at_n":15,"title":"Welcome, you made it","text":"Today is the day. Drink plenty of water, eat well, and say hello at the front desk. Your coaches already know your goals."}
  ]'::jsonb;
begin
  select case when value ~ '^\s*\{' then value::jsonb else '{}'::jsonb end into cfg from public.app_settings where key='prearrival';
  cfg := coalesce(cfg, '{}'::jsonb);

  select id into gb from public.action_groups where name='Get ready: beginners' and not removed limit 1;
  if gb is null then
    insert into public.action_groups(name, notes, items) values ('Get ready: beginners',
      'For guests who are new to Muay Thai, in the two weeks before they arrive. Day 1 is 14 days before arrival, day 15 is arrival day.',
      '[
        {"id":"pa-b-hi","kind":"note","at_mode":"day","at_n":1,"title":"Welcome to the team","text":"Your coaches can already see your answers, so we know what you want from your trip. For the next two weeks, start with the small daily habits below. Nothing hard, just getting your body ready."},
        {"id":"pa-b-water","kind":"habit","at_mode":"day","at_n":1,"title":"Drink 2 to 3 litres of water","text":"Start now, so it is easy in the heat.","habit":{"freq":"daily","days":[],"times":1,"weeks":2}},
        {"id":"pa-b-walk","kind":"habit","at_mode":"day","at_n":1,"title":"Walk or easy jog for 20 minutes","text":"Easy pace. You should be able to talk.","habit":{"freq":"week","days":[],"times":3,"weeks":2}},
        {"id":"pa-b-stretch","kind":"habit","at_mode":"day","at_n":1,"title":"Stretch for 10 minutes","text":"Hips, hamstrings and calves. It makes kicking much easier.","habit":{"freq":"daily","days":[],"times":1,"weeks":2}},
        {"id":"pa-b-w1","kind":"weight","at_mode":"day","at_n":1,"title":"Log your weight","text":"Morning, before breakfast. It is just a starting point for you and your coach."},
        {"id":"pa-b-stance","kind":"note","at_mode":"day","at_n":3,"title":"Learn your stance and guard","text":"- Feet shoulder width apart, lead foot forward, back heel slightly up\n- Hands up by your cheeks, elbows in\n- Chin down\n\nStand in front of a mirror for 2 minutes a day and hold it. Your coach will fix the details on day one."},
        {"id":"pa-b-shadow","kind":"note","at_mode":"day","at_n":6,"title":"Your first shadow boxing","text":"Three rounds of 2 minutes, 1 minute rest:\n- Round 1: just move around in your stance\n- Round 2: add jab and cross\n- Round 3: add a step forward and back\n\nSlow and relaxed is perfect."},
        {"id":"pa-b-w2","kind":"weight","at_mode":"day","at_n":8,"title":"Weekly weigh in","text":"Same time as last week, so the numbers compare."},
        {"id":"pa-b-kicks","kind":"note","at_mode":"day","at_n":9,"title":"What a class looks like","text":"A warm up and skipping, technique with a partner, pad rounds with a coach, then bag work and conditioning. Go at your own pace, the coaches adjust everything for beginners."}
      ]'::jsonb || common_end) returning id into gb;
  end if;

  select id into ge from public.action_groups where name='Get ready: experienced' and not removed limit 1;
  if ge is null then
    insert into public.action_groups(name, notes, items) values ('Get ready: experienced',
      'For guests who already train, in the two weeks before they arrive. Day 1 is 14 days before arrival, day 15 is arrival day.',
      '[
        {"id":"pa-e-hi","kind":"note","at_mode":"day","at_n":1,"title":"Welcome to the team","text":"Your coaches can already see your answers. Arrive fit and you will get far more out of every pad round. Here is a simple plan for the next two weeks."},
        {"id":"pa-e-water","kind":"habit","at_mode":"day","at_n":1,"title":"Drink 3 litres of water","text":"Training in the heat needs more than you think.","habit":{"freq":"daily","days":[],"times":1,"weeks":2}},
        {"id":"pa-e-run","kind":"habit","at_mode":"day","at_n":1,"title":"Run or skip for 30 minutes","text":"Steady pace. Skipping counts.","habit":{"freq":"week","days":[],"times":4,"weeks":2}},
        {"id":"pa-e-shadow","kind":"habit","at_mode":"day","at_n":1,"title":"Shadow box 5 rounds","text":"3 minutes each, 1 minute rest. Stay in your stance, keep your guard up when you throw.","habit":{"freq":"week","days":[],"times":4,"weeks":2}},
        {"id":"pa-e-w1","kind":"weight","at_mode":"day","at_n":1,"title":"Log your weight","text":"Morning, before breakfast."},
        {"id":"pa-e-sharpen","kind":"note","at_mode":"day","at_n":4,"title":"Tell us what to sharpen","text":"Think about the one or two things you most want to improve: kicks, clinch, defence, cardio. Tell your coach on day one, or message us in the app now."},
        {"id":"pa-e-w2","kind":"weight","at_mode":"day","at_n":8,"title":"Weekly weigh in","text":"Same time as last week."},
        {"id":"pa-e-taper","kind":"note","at_mode":"day","at_n":12,"title":"Ease off before you travel","text":"Keep moving but go lighter for the last 2 or 3 days. Arrive fresh, not sore."}
      ]'::jsonb || common_end) returning id into ge;
  end if;

  select id into gf from public.action_groups where name='Get ready: fight camp' and not removed limit 1;
  if gf is null then
    insert into public.action_groups(name, notes, items) values ('Get ready: fight camp',
      'For guests coming to fight or prepare for a fight, in the two weeks before they arrive. Day 1 is 14 days before arrival, day 15 is arrival day.',
      '[
        {"id":"pa-f-hi","kind":"note","at_mode":"day","at_n":1,"title":"Welcome to fight camp","text":"Your coaches can see your answers and your fight goals. A coach will be in touch about your weight class and plan. Until then, build your base with the habits below."},
        {"id":"pa-f-water","kind":"habit","at_mode":"day","at_n":1,"title":"Drink 3 to 4 litres of water","text":"Every day, not just training days.","habit":{"freq":"daily","days":[],"times":1,"weeks":2}},
        {"id":"pa-f-run","kind":"habit","at_mode":"day","at_n":1,"title":"Run 5 km","text":"Steady pace. Thai camps start with a run.","habit":{"freq":"week","days":[],"times":5,"weeks":2}},
        {"id":"pa-f-shadow","kind":"habit","at_mode":"day","at_n":1,"title":"Shadow box 6 rounds","text":"3 minutes each, 1 minute rest, fight pace in the last round.","habit":{"freq":"week","days":[],"times":5,"weeks":2}},
        {"id":"pa-f-w1","kind":"weight","at_mode":"day","at_n":1,"title":"Log your weight","text":"Morning, before breakfast. Log it twice a week from now on so your coach can plan your weight."},
        {"id":"pa-f-food","kind":"food","at_mode":"day","at_n":2,"title":"Start your food diary","text":"Snap your meals in the app. No need to change anything yet, your coach just wants to see where you start."},
        {"id":"pa-f-w2","kind":"weight","at_mode":"day","at_n":5,"title":"Weigh in","text":"Same time of day as before."},
        {"id":"pa-f-w3","kind":"weight","at_mode":"day","at_n":8,"title":"Weigh in","text":"Same time of day as before."},
        {"id":"pa-f-pt","kind":"note","at_mode":"day","at_n":10,"title":"Book your first private","text":"Fighters get the most from a private in the first week, so the coach can see where you are. Book it in the app under Privates."},
        {"id":"pa-f-w4","kind":"weight","at_mode":"day","at_n":12,"title":"Weigh in","text":"Last one before you fly."}
      ]'::jsonb || common_end) returning id into gf;
  end if;

  cfg := jsonb_set(cfg, '{groups}', coalesce(cfg->'groups','{}'::jsonb) || jsonb_build_object(
    'beginner', coalesce(nullif(cfg->'groups'->>'beginner',''), gb::text),
    'experienced', coalesce(nullif(cfg->'groups'->>'experienced',''), ge::text),
    'fight', coalesce(nullif(cfg->'groups'->>'fight',''), gf::text)));
  update public.app_settings set value=cfg::text, updated_at=now() where key='prearrival';
end $f$;
revoke all on function private.prearrival_seed() from public, anon, authenticated;
select private.prearrival_seed();
