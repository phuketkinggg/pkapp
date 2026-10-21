-- Social posts: a video can go out as a Reel (Instagram and Facebook) or as an Instagram Trial Reel
-- (shown to people who do not follow you first; it goes to followers when you share it, or automatically if it does well).
alter table public.social_posts add column if not exists kind text not null default 'post';
alter table public.social_posts add column if not exists trial_strategy text;
do $$ begin
  alter table public.social_posts add constraint social_posts_kind_check check (kind in ('post','reel','trial'));
exception when duplicate_object then null; end $$;
update public.social_posts set kind = 'reel' where kind = 'post' and media @> '[{"type":"video"}]'::jsonb;

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.social_save(jsonb)'::regprocedure);
  if position('v_kind' in d) > 0 then return; end if;
  n := replace(d, 'v_ok boolean := coalesce((p->>''approve'')::boolean,false);',
    'v_ok boolean := coalesce((p->>''approve'')::boolean,false); v_kind text := coalesce(nullif(p->>''kind'',''''),''post''); v_trial text := case when p->>''trial_strategy'' = ''SS_PERFORMANCE'' then ''SS_PERFORMANCE'' else ''MANUAL'' end;');
  n := replace(n, '  if v_id is not null then
    select * into v_old',
'  if v_kind not in (''post'',''reel'',''trial'') then raise exception ''Bad post type.''; end if;
  if v_kind = ''post'' and v_vid > 0 then v_kind := ''reel''; end if;
  if v_kind in (''reel'',''trial'') and v_vid = 0 and v_ok then raise exception ''A Reel needs a video. Add one, or choose Post.''; end if;
  if v_kind = ''trial'' then v_pl := array[''instagram'']; end if;
  if v_kind <> ''trial'' then v_trial := null; end if;
  if v_id is not null then
    select * into v_old');
  n := replace(n, 'insert into public.social_posts(brief,caption,media,platforms,post_at,status,approved_by,approved_at)
    values (left(coalesce(p->>''brief'',''''),2000), v_cap, v_media, v_pl, v_at, v_status,',
    'insert into public.social_posts(kind,trial_strategy,brief,caption,media,platforms,post_at,status,approved_by,approved_at)
    values (v_kind, v_trial, left(coalesce(p->>''brief'',''''),2000), v_cap, v_media, v_pl, v_at, v_status,');
  n := replace(n, 'update public.social_posts set brief=left(', 'update public.social_posts set kind=v_kind, trial_strategy=v_trial, brief=left(');
  if n = d or position('v_kind, v_trial' in n) = 0 or position('kind=v_kind' in n) = 0 then raise exception 'social_save not changed'; end if;
  execute n;

  d := pg_get_functiondef('public.social_take()'::regprocedure);
  n := replace(d, 'returning s.id, s.caption, s.media, s.platforms, s.results)', 'returning s.id, s.caption, s.media, s.platforms, s.results, s.kind, s.trial_strategy)');
  if n = d then raise exception 'social_take not changed'; end if;
  execute n;
end $$;
