delete from mf.template where name like 'hours_clear:%';
insert into mf.template (ord, phase, kind, name, sql) values (304001, 3, 'patch', 'hours_clear:304001', $TPL$create table if not exists __P__.staff_hours_cleared (
  key text primary key,
  day date not null,
  cleared_by uuid,
  cleared_at timestamptz not null default now()
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (304002, 3, 'patch', 'hours_clear:304002', $TPL$alter table __P__.staff_hours_cleared enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002601, 10, 'patch', 'hours_clear:1002601', $TPL$create index if not exists staff_hours_cleared_day on __P__.staff_hours_cleared(day);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404001, 4, 'patch', 'hours_clear:404001', $TPL$create or replace function __Q__.hours_key(m jsonb) returns text language sql immutable set search_path = '' as $f$
  select case when m ? 'entry_id' then 'entry|' || (m->>'entry_id')
    else coalesce(m->>'kind','') || '|' || coalesce(m->>'staff_id','') || '|' || coalesce(m->>'day','') || '|' || coalesce(m->>'ref_id','') || '|' || coalesce(m->>'time','') end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404002, 4, 'patch', 'hours_clear:404002', $TPL$create or replace function __Q__.hours_clear_filter(j jsonb) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare k text;
begin
  if not __Q__.feature('hours_clear', true) then return j; end if;
  foreach k in array array['missed','missed_classes','missed_shifts','missed_sessions'] loop
    if j ? k then
      j := jsonb_set(j, array[k], (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(j->k) with ordinality t(x, o)
        where not exists (select 1 from __P__.staff_hours_cleared c where c.key = __Q__.hours_key(x))));
    end if;
  end loop;
  return j || jsonb_build_object('cleared_entries', (select coalesce(jsonb_agg(substr(c.key, 7)), '[]'::jsonb) from __P__.staff_hours_cleared c
    where c.key like 'entry|%' and c.day >= current_date - 400));
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404003, 4, 'patch', 'hours_clear:404003', $TPL$create or replace function __P__.staff_hours_clear(p_items jsonb) returns int language plpgsql security definer set search_path = '' as $f$
declare n int;
begin
  if not __Q__.feature('hours_clear', true) then raise exception 'Clearing is switched off.'; end if;
  if __Q__.real_role() = 'admin' and not __Q__.can('staff') then raise exception 'Your access does not include staff and pay.'; end if;
  if not coalesce(__Q__.staff_role() = 'manager', false) then raise exception 'Only a manager can do this.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 2000 then raise exception 'Choose up to 2000 at a time.'; end if;
  insert into __P__.staff_hours_cleared(key, day, cleared_by)
    select __Q__.hours_key(x), (x->>'day')::date, __Q__.my_staff_id() from jsonb_array_elements(p_items) x where x->>'day' is not null
    on conflict (key) do nothing;
  get diagnostics n = row_count;
  return n;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (404004, 4, 'patch', 'hours_clear:404004', $TPL$create or replace function __P__.staff_hours_unclear(p_from date, p_to date) returns int language plpgsql security definer set search_path = '' as $f$
declare n int;
begin
  if __Q__.real_role() = 'admin' and not __Q__.can('staff') then raise exception 'Your access does not include staff and pay.'; end if;
  if not coalesce(__Q__.staff_role() = 'manager', false) then raise exception 'Only a manager can do this.'; end if;
  delete from __P__.staff_hours_cleared where day between p_from and p_to;
  get diagnostics n = row_count;
  return n;
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198101, 11, 'patch', 'hours_clear:1198101', $TPL$revoke all on function __P__.staff_hours_clear(jsonb), __P__.staff_hours_unclear(date, date) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1198102, 11, 'patch', 'hours_clear:1198102', $TPL$grant execute on function __P__.staff_hours_clear(jsonb), __P__.staff_hours_unclear(date, date) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002602, 10, 'patch', 'hours_clear:1002602', $TPL$do $$
declare d text; n text;
begin
  d := pg_get_functiondef('__P__.staff_hours(date,date)'::regprocedure);
  if position('__Q__.hours_clear_filter(' in d) > 0 then return; end if;
  n := replace(d, 'return jsonb_build_object(', 'return __Q__.hours_clear_filter(jsonb_build_object(');
  n := regexp_replace(n, '\);\s*end\s*\$function\$\s*$', '));
end $function$
');
  if n = d or position('__Q__.hours_clear_filter(' in n) = 0 or n !~ '\)\);\s*end \$function\$\s*$' then raise exception 'staff_hours not changed'; end if;
  execute n;
end $$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'hours_clear:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
