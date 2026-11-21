-- Staff hours: clear items from Needs a look (feature hours_clear).
-- A manager ticks "Not checked in" or "Never checked out" items and clears them, so the list only shows what still needs doing.
-- Cleared items are kept in public.staff_hours_cleared (one key per item) and can be brought back for the dates shown.

create table if not exists public.staff_hours_cleared (
  key text primary key,
  day date not null,
  cleared_by uuid,
  cleared_at timestamptz not null default now()
);
alter table public.staff_hours_cleared enable row level security;
create index if not exists staff_hours_cleared_day on public.staff_hours_cleared(day);

-- the key of one Needs a look item: a missed one by kind, who, day, what and time; a never checked out one by its check in
create or replace function private.hours_key(m jsonb) returns text language sql immutable set search_path = '' as $f$
  select case when m ? 'entry_id' then 'entry|' || (m->>'entry_id')
    else coalesce(m->>'kind','') || '|' || coalesce(m->>'staff_id','') || '|' || coalesce(m->>'day','') || '|' || coalesce(m->>'ref_id','') || '|' || coalesce(m->>'time','') end
$f$;

-- takes cleared items out of the staff hours answer, and lists cleared check ins (for never checked out)
create or replace function private.hours_clear_filter(j jsonb) returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare k text;
begin
  if not private.feature('hours_clear', true) then return j; end if;
  foreach k in array array['missed','missed_classes','missed_shifts','missed_sessions'] loop
    if j ? k then
      j := jsonb_set(j, array[k], (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(j->k) with ordinality t(x, o)
        where not exists (select 1 from public.staff_hours_cleared c where c.key = private.hours_key(x))));
    end if;
  end loop;
  return j || jsonb_build_object('cleared_entries', (select coalesce(jsonb_agg(substr(c.key, 7)), '[]'::jsonb) from public.staff_hours_cleared c
    where c.key like 'entry|%' and c.day >= current_date - 400));
end $f$;

-- clear items: p_items are the items as the app has them (missed ones as they are, never checked out ones as {entry_id, day})
create or replace function public.staff_hours_clear(p_items jsonb) returns int language plpgsql security definer set search_path = '' as $f$
declare n int;
begin
  if not private.feature('hours_clear', true) then raise exception 'Clearing is switched off.'; end if;
  if private.real_role() = 'admin' and not private.can('staff') then raise exception 'Your access does not include staff and pay.'; end if;
  if not coalesce(private.staff_role() = 'manager', false) then raise exception 'Only a manager can do this.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 2000 then raise exception 'Choose up to 2000 at a time.'; end if;
  insert into public.staff_hours_cleared(key, day, cleared_by)
    select private.hours_key(x), (x->>'day')::date, private.my_staff_id() from jsonb_array_elements(p_items) x where x->>'day' is not null
    on conflict (key) do nothing;
  get diagnostics n = row_count;
  return n;
end $f$;

-- bring back everything cleared for these dates
create or replace function public.staff_hours_unclear(p_from date, p_to date) returns int language plpgsql security definer set search_path = '' as $f$
declare n int;
begin
  if private.real_role() = 'admin' and not private.can('staff') then raise exception 'Your access does not include staff and pay.'; end if;
  if not coalesce(private.staff_role() = 'manager', false) then raise exception 'Only a manager can do this.'; end if;
  delete from public.staff_hours_cleared where day between p_from and p_to;
  get diagnostics n = row_count;
  return n;
end $f$;

revoke all on function public.staff_hours_clear(jsonb), public.staff_hours_unclear(date, date) from public, anon;
grant execute on function public.staff_hours_clear(jsonb), public.staff_hours_unclear(date, date) to authenticated;

-- staff_hours answers through the filter
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.staff_hours(date,date)'::regprocedure);
  if position('private.hours_clear_filter(' in d) > 0 then return; end if;
  n := replace(d, 'return jsonb_build_object(', 'return private.hours_clear_filter(jsonb_build_object(');
  n := regexp_replace(n, '\);\s*end\s*\$function\$\s*$', '));
end $function$
');
  if n = d or position('private.hours_clear_filter(' in n) = 0 or n !~ '\)\);\s*end \$function\$\s*$' then raise exception 'staff_hours not changed'; end if;
  execute n;
end $$;
