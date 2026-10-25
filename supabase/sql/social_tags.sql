-- Social posts: tag the business location and add Instagram collaborators (up to 3 accounts, they accept the invite in Instagram).
-- Feature switch: social_tags (the app hides the fields when it is off).

alter table public.social_posts add column if not exists tag_place boolean not null default true;
alter table public.social_posts add column if not exists collaborators text[] not null default '{}';

-- Instagram usernames: without @, small letters, letters, numbers, dot and underscore, at most 3
create or replace function private.social_collab(p jsonb) returns text[] language sql immutable set search_path to '' as $$
  select coalesce((select array_agg(u) from (select u from (
    select distinct lower(regexp_replace(btrim(x), '^@+', '')) u
    from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) x) t0
    where u ~ '^[a-z0-9._]{1,30}$' order by u limit 3) t), '{}')
$$;

do $$ declare s text;
begin
  s := pg_get_functiondef('public.social_save(jsonb)'::regprocedure);
  if s like '%social_collab%' then return; end if;
  s := replace(s, $a$insert into public.social_posts(kind,trial_strategy,brief,$a$, $a$insert into public.social_posts(tag_place,collaborators,kind,trial_strategy,brief,$a$);
  s := replace(s, $a$values (v_kind, v_trial,$a$, $a$values (coalesce((p->>'tag_place')::boolean, true), private.social_collab(p->'collaborators'), v_kind, v_trial,$a$);
  s := replace(s, $a$update public.social_posts set kind=v_kind,$a$, $a$update public.social_posts set tag_place=coalesce((p->>'tag_place')::boolean, true), collaborators=private.social_collab(p->'collaborators'), kind=v_kind,$a$);
  if (length(s) - length(replace(s, 'social_collab', ''))) / 13 <> 2 then raise notice 'social_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;

do $$ declare s text;
begin
  s := pg_get_functiondef('public.social_take()'::regprocedure);
  if s like '%tag_place%' then return; end if;
  s := replace(s, $a$returning s.id, s.caption, s.media, s.platforms, s.results, s.kind, s.trial_strategy)$a$,
    $a$returning s.id, s.caption, s.media, s.platforms, s.results, s.kind, s.trial_strategy, s.tag_place, s.collaborators)$a$);
  if s not like '%tag_place%' then raise notice 'social_take is a different version here: skipped.'; return; end if;
  execute s;
end $$;

-- the usual posting time for new posts (Social media, Posting time), Bangkok time
insert into public.app_settings (key, value) values ('social_time', '20:30') on conflict (key) do nothing;
