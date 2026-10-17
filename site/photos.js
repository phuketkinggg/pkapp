/* Every photo spot on the Phuket King website. Shared by the website pages and the app's Settings > Website photos.
   The starting photo for each spot lives in the app's storage under promos/site/default/. A manager can swap any of them in the app. */
(function(){
var B='https://jijnshwduhgegacfvpkh.supabase.co/storage/v1/object/public/promos/site/default/';
var L=[
  ['home_hero','Home','Top of the page (big, wide)','home_hero.webp'],
  ['home_beginners','Home','Training card: Beginners','home_beginners.webp'],
  ['home_fitness','Home','Training card: Fitness','home_fitness.webp'],
  ['home_fighters','Home','Training card: Fighters','home_fighters.jpg'],
  ['home_about','Home','About us section','home_about.webp'],
  ['coach_max','Home','Coach: Kru Max','coach_max.jpg'],
  ['coach_tom','Home','Coach: Coach Tom','coach_tom.jpg'],
  ['coach_mang','Home','Coach: Kru Mang','coach_mang.jpg'],
  ['coach_ris','Home','Coach: Kru Ris','coach_ris.jpg'],
  ['coach_chi','Home','Coach: Kru Chi','coach_chi.jpg'],
  ['coach_phum','Home','Coach: Kru Phum','coach_phum.jpg'],
  ['home_stay','Home','Stay at Pangea band (big, wide)','home_stay.jpg'],
  ['home_location','Home','Location section','home_location.webp'],
  ['prices_hero','Prices','Top of the page (big, wide)','prices_hero.webp'],
  ['dtv_hero','DTV','Top of the page (big, wide)','home_hero.webp'],
  ['blog_hero','Blog','Top of the page (big, wide)','about_train.webp'],
  ['shop_hero','Shop','Top of the page (big, wide)','home_fighters.jpg'],
  ['about_hero','About','Top of the page (big, wide)','about_hero.webp'],
  ['about_why','About','Why we built it','about_why.webp'],
  ['about_train','About','Card: Train','about_train.webp'],
  ['about_recover','About','Card: Recover','about_recover.webp'],
  ['about_stay','About','Card: Stay','about_stay.webp'],
  ['about_fuel','About','Card: Fuel','about_fuel.webp'],
  ['about_day','About','A typical day','about_day.webp'],
  ['about_family','About','You are becoming family (big group photo)','about_family.webp'],
  ['about_strip1','About','Photo strip 1','about_strip1.webp'],
  ['about_strip2','About','Photo strip 2','about_strip2.webp'],
  ['about_strip3','About','Photo strip 3','about_strip3.jpg'],
  ['about_strip4','About','Photo strip 4','about_strip4.webp'],
  ['wellness_hero','Wellness','Top of the page (big, wide)','wellness_hero.jpg'],
  ['wellness_yoga','Wellness','Yoga','wellness_yoga.jpg'],
  ['wellness_steam','Wellness','Herbal steam room','wellness_steam.webp'],
  ['wellness_sauna','Wellness','Dry sauna','wellness_sauna.webp'],
  ['wellness_ice','Wellness','Ice bath','wellness_ice.webp'],
  ['wellness_redlight','Wellness','Red light therapy','wellness_redlight.webp']
];
window.PK_PHOTOS=L.map(function(x){ return {id:x[0],page:x[1],label:x[2],src:B+x[3]}; });
})();
