-- Staff and coach profile videos (a 360 view), shown instead of the photo in the app and on the websites.
-- The website team ("The Phuket King family") comes from Staff: who shows, their title, the text and the order.
alter table public.staff add column if not exists video_url text;
alter table public.staff add column if not exists web_show boolean not null default false;
alter table public.staff add column if not exists web_name text;
alter table public.staff add column if not exists web_title text;
alter table public.staff add column if not exists web_about text;
alter table public.staff add column if not exists web_sort int not null default 100;
grant select (video_url, web_show, web_name, web_title, web_about, web_sort) on public.staff to authenticated;

-- videos can go in the public promos bucket (up to 50 MB)
update storage.buckets set file_size_limit = 52428800,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime']
where id = 'promos';

-- online private booking: the coach's video
do $$ declare s text;
begin
  s := pg_get_functiondef('public.private_book_slots(date,integer)'::regprocedure);
  if s not like '%video_url%' then
    s := replace(s, $a$'photo', s.photo_url,$a$, $a$'photo', s.photo_url, 'video', (select x.video_url from public.staff x where x.id = s.id),$a$);
    if s not like '%video_url%' then raise exception 'private_book_slots patch did not apply'; end if;
    execute s;
  end if;
end $$;
