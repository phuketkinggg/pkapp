-- YouTube title (feature youtube_shorts): a reel can have its own title for YouTube Shorts. Empty: the first line of the caption, as before.
-- Also: the post list now gives back everything saved on a post (type, trial, tags, TikTok choices, YouTube title), so opening a post keeps them.
-- Patches check they applied and skip cleanly where a database has an older version.
alter table public.social_posts add column if not exists yt_title text;

do $$ declare s text; n text;
begin
  if to_regprocedure('public.social_save(jsonb)') is null then raise notice 'social_yt_title: no social_save here, skipped'; return; end if;
  s := pg_get_functiondef('public.social_save(jsonb)'::regprocedure);
  if s like '%yt_title%' then return; end if;
  n := replace(s, 'insert into public.social_posts(tiktok,', 'insert into public.social_posts(yt_title,tiktok,');
  n := replace(n, $a$values (private.social_tt(p->'tiktok'),$a$, $a$values (nullif(left(btrim(coalesce(p->>'yt_title','')), 100), ''), private.social_tt(p->'tiktok'),$a$);
  n := replace(n, $a$update public.social_posts set tiktok=private.social_tt(p->'tiktok'),$a$, $a$update public.social_posts set yt_title=nullif(left(btrim(coalesce(p->>'yt_title','')), 100), ''), tiktok=private.social_tt(p->'tiktok'),$a$);
  if (length(n) - length(replace(n, 'yt_title', ''))) / 8 < 4 then raise notice 'social_yt_title: social_save is a different version here, skipped'; return; end if;
  execute n;
end $$;

do $$ declare s text; n text;
begin
  if to_regprocedure('public.social_take()') is null then return; end if;
  s := pg_get_functiondef('public.social_take()'::regprocedure);
  if s like '%s.yt_title%' then return; end if;
  n := replace(s, 's.collaborators, s.tiktok)', 's.collaborators, s.tiktok, s.yt_title)');
  if n = s then raise notice 'social_yt_title: social_take is a different version here, skipped'; return; end if;
  execute n;
end $$;

do $$ declare s text; n text;
begin
  if to_regprocedure('public.social_list()') is null then return; end if;
  s := pg_get_functiondef('public.social_list()'::regprocedure);
  if s like '%to_jsonb(s)%' then return; end if;
  n := replace(s, 'jsonb_agg(jsonb_build_object(', 'jsonb_agg((to_jsonb(s) - ''removed'') || jsonb_build_object(');
  if n = s then raise notice 'social_yt_title: social_list is a different version here, skipped'; return; end if;
  execute n;
end $$;
