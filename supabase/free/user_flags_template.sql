delete from mf.template where name like 'user_flags:%';
insert into mf.template (ord, phase, kind, name, sql) values (303431, 3, 'patch', 'user_flags:303431', $TPL$create table if not exists __P__.user_flags (
  user_id uuid not null,
  key text not null check (key ~ '^[a-z_]{2,30}$'),
  value text,
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303432, 3, 'patch', 'user_flags:303432', $TPL$alter table __P__.user_flags enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197551, 11, 'patch', 'user_flags:1197551', $TPL$revoke all on __P__.user_flags from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403541, 4, 'patch', 'user_flags:403541', $TPL$create or replace function __P__.my_flags() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from __P__.user_flags where user_id = auth.uid()
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403542, 4, 'patch', 'user_flags:403542', $TPL$create or replace function __P__.my_flag_set(p_key text, p_value text) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_key !~ '^[a-z_]{2,30}$' then raise exception 'Unknown setting.'; end if;
  insert into __P__.user_flags (user_id, key, value) values (auth.uid(), p_key, left(p_value, 200))
    on conflict (user_id, key) do update set value = excluded.value, updated_at = now();
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197552, 11, 'patch', 'user_flags:1197552', $TPL$revoke all on function __P__.my_flags() from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197553, 11, 'patch', 'user_flags:1197553', $TPL$revoke all on function __P__.my_flag_set(text, text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197554, 11, 'patch', 'user_flags:1197554', $TPL$grant execute on function __P__.my_flags() to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197555, 11, 'patch', 'user_flags:1197555', $TPL$grant execute on function __P__.my_flag_set(text, text) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'user_flags:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
