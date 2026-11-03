-- Muay Friend Support page (muayfriend.com/support/): tutorial videos in English and Thai.
-- Anyone can watch. The Muay Friend team (emails in mf.cfg team_emails) adds, edits and removes videos on the page itself,
-- after signing in to the Muay Friend app on the same device (the sign-in is shared on muayfriend.com). Video files go in the public storage bucket "support"; a YouTube or other link works too.
insert into mf.cfg (key, value) values ('team_emails', '["hello@muayfriend.com"]') on conflict (key) do nothing;

create table if not exists mf.support_videos (
  id uuid primary key default gen_random_uuid(),
  topic text not null default 'start',
  title_en text not null, title_th text,
  body_en text, body_th text,
  video_url text not null, file_path text,
  sort int not null default 100,
  published boolean not null default true,
  made_at timestamptz not null default now(), changed_at timestamptz not null default now());
alter table mf.support_videos enable row level security;

create or replace function public.mf_is_team() returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce(lower(auth.jwt() ->> 'email') in (select lower(x) from jsonb_array_elements_text((select value from mf.cfg where key = 'team_emails')) x), false)
$$;

-- for everyone: the published videos
create or replace function public.mf_support_list() returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(to_jsonb(v) - 'file_path' order by v.sort, v.made_at), '[]'::jsonb)
    from mf.support_videos v where v.published or public.mf_is_team()
$$;
create or replace function public.mf_support_team() returns boolean language sql stable security definer set search_path to '' as $$ select public.mf_is_team() $$;

-- for the team: add or change a video, remove one
drop function if exists public.mf_support_save(jsonb);
create or replace function public.mf_support_save(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $$
declare i uuid := nullif(p->>'id', '')::uuid; old text;
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can change videos.'; end if;
  if coalesce(btrim(p->>'title_en'), '') = '' then raise exception 'Add a title in English.'; end if;
  if coalesce(p->>'video_url', '') !~ '^https://' then raise exception 'Add the video: upload a file or paste a link.'; end if;
  if i is null then
    insert into mf.support_videos (topic, title_en, title_th, body_en, body_th, video_url, file_path, sort, published)
    values (coalesce(nullif(p->>'topic', ''), 'start'), btrim(p->>'title_en'), nullif(btrim(p->>'title_th'), ''), nullif(btrim(p->>'body_en'), ''), nullif(btrim(p->>'body_th'), ''),
            p->>'video_url', nullif(p->>'file_path', ''), coalesce((p->>'sort')::int, 100), coalesce((p->>'published')::boolean, true))
    returning id into i;
  else
    select file_path into old from mf.support_videos where id = i;
    update mf.support_videos set topic = coalesce(nullif(p->>'topic', ''), topic), title_en = btrim(p->>'title_en'), title_th = nullif(btrim(p->>'title_th'), ''),
      body_en = nullif(btrim(p->>'body_en'), ''), body_th = nullif(btrim(p->>'body_th'), ''), video_url = p->>'video_url',
      file_path = case when p ? 'file_path' then nullif(p->>'file_path', '') else file_path end,
      sort = coalesce((p->>'sort')::int, sort), published = coalesce((p->>'published')::boolean, published), changed_at = now()
    where id = i;
    if not (p ? 'file_path') or old is not distinct from nullif(p->>'file_path', '') then old := null; end if;
  end if;
  return jsonb_build_object('id', i, 'old_file', old); -- the page removes a replaced file from storage
end $$;
create or replace function public.mf_support_delete(p_id uuid) returns text language plpgsql security definer set search_path to '' as $$
declare f text;
begin
  if not public.mf_is_team() then raise exception 'Only the Muay Friend team can change videos.'; end if;
  delete from mf.support_videos where id = p_id returning file_path into f;
  return f; -- the page removes the file from storage
end $$;
revoke all on function public.mf_support_list(), public.mf_support_team(), public.mf_support_save(jsonb), public.mf_support_delete(uuid) from public;
grant execute on function public.mf_support_list(), public.mf_support_team() to anon, authenticated;
grant execute on function public.mf_support_save(jsonb), public.mf_support_delete(uuid) to authenticated;

-- the video files: anyone can watch, only the team can upload or remove
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('support', 'support', true, null, array['video/mp4', 'video/webm', 'video/quicktime', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "support team upload" on storage.objects;
drop policy if exists "support team change" on storage.objects;
drop policy if exists "support team remove" on storage.objects;
drop policy if exists "support team list" on storage.objects;
create policy "support team list" on storage.objects for select to authenticated using (bucket_id = 'support' and public.mf_is_team());
create policy "support team upload" on storage.objects for insert to authenticated with check (bucket_id = 'support' and public.mf_is_team());
create policy "support team change" on storage.objects for update to authenticated using (bucket_id = 'support' and public.mf_is_team());
create policy "support team remove" on storage.objects for delete to authenticated using (bucket_id = 'support' and public.mf_is_team());
revoke all on function public.mf_is_team() from public;
grant execute on function public.mf_is_team() to anon, authenticated;
notify pgrst, 'reload schema';
