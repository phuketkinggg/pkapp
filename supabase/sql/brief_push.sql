-- Arriving tomorrow in the app (feature brief_push): at 6pm, with the coaches' arrivals email, coaches and managers get a phone notice
-- with tomorrow's new guests. Tapping it opens Coaching, Arriving soon.

create or replace function private.brief_push(p_day date default null) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare d date := coalesce(p_day, private.bkk_today() + 1); g jsonb; n int;
begin
  if not private.feature('brief_push', true) then return null; end if;
  g := public.coach_brief(d)->'guests';
  n := coalesce(jsonb_array_length(g), 0);
  if n = 0 then return null; end if;
  return jsonb_build_object(
    'title', 'Arriving tomorrow: ' || n || case when n = 1 then ' guest' else ' guests' end,
    'body', left((select string_agg(x->>'name' || coalesce(' (' || (x->>'room') || ')', ''), ', ' order by x->>'name') from jsonb_array_elements(g) x) || '. Tap to see who they are.', 180),
    'tag', 'brief-' || d, 'url', '#arriving',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from public.push_subs s join public.staff st on st.id = s.staff_id where s.off_at is null and st.active and st.role in ('coach','manager')), '[]'::jsonb));
end $f$;

do $p$
declare d text; n text;
begin
  if to_regprocedure('public.push_targets(text,uuid)') is null or to_regprocedure('public.coach_brief(date)') is null then raise notice 'brief_push: skipped, older version'; return; end if;
  d := pg_get_functiondef('public.push_targets(text,uuid)'::regprocedure);
  if position('private.brief_push(' in d) > 0 then return; end if;
  n := replace(d, '  if p_kind <> ''arrival'' then return null; end if;', '  if p_kind = ''brief'' then return private.brief_push(); end if;
  if p_kind <> ''arrival'' then return null; end if;');
  if n = d then raise notice 'brief_push: push_targets is different, skipped'; return; end if;
  execute n;
end $p$;
