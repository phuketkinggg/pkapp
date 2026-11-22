delete from mf.template where name like 'brief_push:%';
insert into mf.template (ord, phase, kind, name, sql) values (404401, 4, 'patch', 'brief_push:404401', $TPL$create or replace function __Q__.brief_push(p_day date default null) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare d date := coalesce(p_day, __Q__.bkk_today() + 1); g jsonb; n int;
begin
  if not __Q__.feature('brief_push', true) then return null; end if;
  g := __P__.coach_brief(d)->'guests';
  n := coalesce(jsonb_array_length(g), 0);
  if n = 0 then return null; end if;
  return jsonb_build_object(
    'title', 'Arriving tomorrow: ' || n || case when n = 1 then ' guest' else ' guests' end,
    'body', left((select string_agg(x->>'name' || coalesce(' (' || (x->>'room') || ')', ''), ', ' order by x->>'name') from jsonb_array_elements(g) x) || '. Tap to see who they are.', 180),
    'tag', 'brief-' || d, 'url', '#arriving',
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
      from __P__.push_subs s join __P__.staff st on st.id = s.staff_id where s.off_at is null and st.active and st.role in ('coach','manager')), '[]'::jsonb));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1003001, 10, 'patch', 'brief_push:1003001', $TPL$do $p$
declare d text; n text;
begin
  if to_regprocedure('__P__.push_targets(text,uuid)') is null or to_regprocedure('__P__.coach_brief(date)') is null then raise notice 'brief_push: skipped, older version'; return; end if;
  d := pg_get_functiondef('__P__.push_targets(text,uuid)'::regprocedure);
  if position('__Q__.brief_push(' in d) > 0 then return; end if;
  n := replace(d, '  if p_kind <> ''arrival'' then return null; end if;', '  if p_kind = ''brief'' then return __Q__.brief_push(); end if;
  if p_kind <> ''arrival'' then return null; end if;');
  if n = d then raise notice 'brief_push: push_targets is different, skipped'; return; end if;
  execute n;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'brief_push:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
