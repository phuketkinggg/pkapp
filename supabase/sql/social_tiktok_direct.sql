-- TikTok direct posting: a reel can go straight to the TikTok profile instead of the drafts.
-- TikTok asks the poster to choose who can see it (no default), and whether comments, Duet and Stitch are allowed,
-- and to say if the video promotes their own business or is a paid partnership. Those choices are kept on the post.
-- Until TikTok has reviewed the app, TikTok only allows "Only me" posts.

alter table public.social_posts add column if not exists tiktok jsonb not null default '{}'::jsonb;

-- the TikTok choices, cleaned: direct (or draft), privacy, comment, duet, stitch, brand_organic, brand_content
create or replace function private.social_tt(p jsonb) returns jsonb language sql immutable set search_path to '' as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then '{}'::jsonb else jsonb_build_object(
    'direct', coalesce((p->>'direct')::boolean, false),
    'privacy', case when p->>'privacy' in ('PUBLIC_TO_EVERYONE','MUTUAL_FOLLOW_FRIENDS','FOLLOWER_OF_CREATOR','SELF_ONLY') then p->>'privacy' else '' end,
    'comment', coalesce((p->>'comment')::boolean, true), 'duet', coalesce((p->>'duet')::boolean, true), 'stitch', coalesce((p->>'stitch')::boolean, true),
    'brand_organic', coalesce((p->>'brand_organic')::boolean, false), 'brand_content', coalesce((p->>'brand_content')::boolean, false)) end
$$;

do $$ declare s text;
begin
  s := pg_get_functiondef('public.social_save(jsonb)'::regprocedure);
  if s like '%social_tt%' then return; end if;
  s := replace(s, 'insert into public.social_posts(tag_place,collaborators,', 'insert into public.social_posts(tiktok,tag_place,collaborators,');
  s := replace(s, $a$values (coalesce((p->>'tag_place')::boolean, true),$a$, $a$values (private.social_tt(p->'tiktok'), coalesce((p->>'tag_place')::boolean, true),$a$);
  s := replace(s, $a$update public.social_posts set tag_place=$a$, $a$update public.social_posts set tiktok=private.social_tt(p->'tiktok'), tag_place=$a$);
  s := replace(s, $a$    if 'tiktok' = any(v_pl) and v_vid = 0 then raise exception 'TikTok needs a video.'; end if;$a$,
    $a$    if 'tiktok' = any(v_pl) and v_vid = 0 then raise exception 'TikTok needs a video.'; end if;
    if v_ok and 'tiktok' = any(v_pl) and (private.social_tt(p->'tiktok')->>'direct')::boolean then
      if private.social_tt(p->'tiktok')->>'privacy' = '' then raise exception 'Choose who can see it on TikTok.'; end if;
      if (private.social_tt(p->'tiktok')->>'brand_content')::boolean and private.social_tt(p->'tiktok')->>'privacy' = 'SELF_ONLY' then raise exception 'A paid partnership can not be Only me on TikTok.'; end if;
    end if;$a$);
  if (length(s) - length(replace(s, 'social_tt', ''))) / 9 < 6 then raise notice 'social_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;

do $$ declare s text;
begin
  s := pg_get_functiondef('public.social_take()'::regprocedure);
  if s like '%s.tiktok%' then return; end if;
  s := replace(s, 's.tag_place, s.collaborators)', 's.tag_place, s.collaborators, s.tiktok)');
  if s not like '%s.tiktok%' then raise notice 'social_take is a different version here: skipped.'; return; end if;
  execute s;
end $$;
