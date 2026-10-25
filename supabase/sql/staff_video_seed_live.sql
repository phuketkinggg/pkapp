-- Phuket King live only: the team that was on the home page, with its titles and text, and Kru Phum's website photo.
update public.staff x set web_show = true, web_title = v.t, web_about = v.a, web_sort = v.o
from (values
  ('Kru Max', 'Head Muay Thai coach', 'A decorated fighter with multiple belts who became one of the finest trainers in Thailand. He knows what you need before you do.', 10),
  ('Tom', 'Founder, strength and mobility', 'Thirty years of elite coaching. Strength and conditioning and FRC mobility, bringing structure, science and precision to the art. Specializes in Technique, Specific coaching for individuals. Struggling with a certain technique, talk to Coach Tom', 20),
  ('Kru Mang', 'Knees and elbows', 'Over 80 fights, back with a sports degree. A gentle giant who will spend a whole round on the details other gyms skip.', 30),
  ('Kru Ris', 'Heavyweight specialist', 'An active fighter at a heavier weight, rare for a Thai. Patient, detailed and strong, ideal for bigger students.', 40),
  ('Kru Chi', 'Clinch and sparring', 'Famous for his forward, never say die style. Intense but controlled, and very strong in the clinch.', 50),
  ('Kru Phum', 'Southpaw, 40 fights', 'At 19, one of our most exciting young fighters. High pressure, sharp technique and a real love for teaching.', 60)
) v(n, t, a, o) where x.name = v.n and x.web_title is null;
update public.staff set web_name = 'Coach Tom' where name = 'Tom' and web_name is null;
update public.staff set photo_url = 'https://jijnshwduhgegacfvpkh.supabase.co/storage/v1/object/public/promos/site/default/coach_phum.jpg' where name = 'Kru Phum' and photo_url is null;
