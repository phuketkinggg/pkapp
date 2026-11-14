delete from mf.template where name like 'user_flags:%';
insert into mf.template (ord, phase, kind, name, sql) values (303421, 3, 'patch', 'user_flags:303421', $TPL$create table if not exists __P__.user_flags (
  user_id uuid not null,
  key text not null check (key ~ '^[a-z_]{2,30}$'),
  value text,
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303422, 3, 'patch', 'user_flags:303422', $TPL$alter table __P__.user_flags enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197521, 11, 'patch', 'user_flags:1197521', $TPL$revoke all on __P__.user_flags from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403521, 4, 'patch', 'user_flags:403521', $TPL$create or replace function __P__.my_flags() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from __P__.user_flags where user_id = auth.uid()
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403522, 4, 'patch', 'user_flags:403522', $TPL$create or replace function __P__.my_flag_set(p_key text, p_value text) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_key !~ '^[a-z_]{2,30}$' then raise exception 'Unknown setting.'; end if;
  insert into __P__.user_flags (user_id, key, value) values (auth.uid(), p_key, left(p_value, 200))
    on conflict (user_id, key) do update set value = excluded.value, updated_at = now();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197522, 11, 'patch', 'user_flags:1197522', $TPL$revoke all on function __P__.my_flags() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197523, 11, 'patch', 'user_flags:1197523', $TPL$revoke all on function __P__.my_flag_set(text, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197524, 11, 'patch', 'user_flags:1197524', $TPL$grant execute on function __P__.my_flags() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197525, 11, 'patch', 'user_flags:1197525', $TPL$grant execute on function __P__.my_flag_set(text, text) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'user_flags:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
