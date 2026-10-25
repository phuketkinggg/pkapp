-- Social posts: Stories (one photo or one video, 24 hours) on Instagram and Facebook. No caption, no YouTube.
-- Feature switch: social_stories (the app hides the Story type when it is off).

alter table public.social_posts drop constraint if exists social_posts_kind_check;
alter table public.social_posts add constraint social_posts_kind_check check (kind in ('post','reel','trial','story'));

do $$ declare s text;
begin
  s := pg_get_functiondef('public.social_save(jsonb)'::regprocedure);
  if s like '%''story''%' then return; end if;
  s := replace(s, $a$if v_kind not in ('post','reel','trial') then$a$, $a$if v_kind not in ('post','reel','trial','story') then$a$);
  s := replace(s, $a$  if v_kind <> 'trial' then v_trial := null; end if;$a$,
    $a$  if v_kind <> 'trial' then v_trial := null; end if;
  -- a story: one photo or one video, Instagram and Facebook only
  if v_kind = 'story' then
    v_pl := coalesce((select array_agg(x) from unnest(v_pl) x where x in ('facebook','instagram')), '{}');
    if v_ok and v_n <> 1 then raise exception 'A story is one photo or one video.'; end if;
  end if;$a$);
  if s not like '%''story''%A story is one photo%' then raise notice 'social_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;
