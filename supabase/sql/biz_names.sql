-- The two built-in businesses are named per install, not in code.
-- app_settings 'acc_names' = {"main": "...", "stay": "..."}: set it first (Phuket King: Phuket King Gym and Pangea Resort).
-- Every function that had a name written in now calls private.biz_main() or private.biz_stay(),
-- and rows recorded under an old built-in name move to the install's own name.

insert into public.app_settings(key, value) values ('acc_names', '{"main":"Phuket King Gym","stay":"Pangea Resort"}') on conflict (key) do nothing;

create or replace function private.biz_main() returns text language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim((select case when value ~ '^\s*\{' then value::jsonb->>'main' end from public.app_settings where key = 'acc_names')), ''), 'Phuket King Gym')
$$;
create or replace function private.biz_stay() returns text language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim((select case when value ~ '^\s*\{' then value::jsonb->>'stay' end from public.app_settings where key = 'acc_names')), ''), 'Pangea Resort')
$$;
revoke all on function private.biz_main() from public, anon;
revoke all on function private.biz_stay() from public, anon;
grant execute on function private.biz_main() to authenticated;
grant execute on function private.biz_stay() to authenticated;

do $$
declare m text := private.biz_main(); st text := private.biz_stay(); r record; s text; olds text[]; o text; n int := 0;
begin
  -- names this install may have in its code or rows: Phuket King's, the Muay Friend demo's, the Massage Mate demo's
  olds := array['Phuket King Gym','Muay Fight Gym','Massage Mate Demo Spa'];
  for r in select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where ns.nspname in ('public','private') and p.prokind = 'f' and p.proname not in ('biz_main','biz_stay')
             and p.prosrc ~ '''(Phuket King Gym|Pangea Resort|Muay Fight Gym|Camp Rooms|Massage Mate Demo Spa|Guest Rooms)''' loop
    s := pg_get_functiondef(r.oid);
    foreach o in array olds || array[m] loop s := replace(s, '''' || o || '''', 'private.biz_main()'); end loop;
    foreach o in array array['Pangea Resort','Camp Rooms','Guest Rooms', st] loop s := replace(s, '''' || o || '''', 'private.biz_stay()'); end loop;
    s := replace(s, E'\n IMMUTABLE', E'\n STABLE');
    execute s; n := n + 1;
  end loop;
  raise notice 'functions changed: %', n;

  -- column defaults
  alter table public.invoices alter column business set default private.biz_main();
  alter table public.places alter column business set default private.biz_stay();

  -- rows recorded under another built-in name
  foreach o in array olds loop
    if o <> m then
      update public.expense_receipts set business = m where business = o;
      update public.acc_entries set business = m where business = o;
      update public.acc_entries set to_business = m where to_business = o;
      update public.acc_recurring set business = m where business = o;
      update public.invoices set business = m where business = o;
      update public.places set business = m where business = o;
      update public.payments set fee_business = m where fee_business = o;
      update public.packages set acc_business = m where acc_business = o;
      update public.shop_categories set acc_business = m where acc_business = o;
      update public.shop_locations set acc_business = m where acc_business = o;
      update public.app_settings set value = replace(value, '"' || o || '"', to_jsonb(m)::text) where key in ('acc_structure','invoice_template','acc_recurring') and value like '%' || o || '%';
      update public.acc_recurring set split = replace(split::text, '"' || o || '"', to_jsonb(m)::text)::jsonb where split::text like '%' || o || '%';
    end if;
  end loop;
  foreach o in array array['Pangea Resort','Camp Rooms','Guest Rooms'] loop
    if o <> st then
      update public.expense_receipts set business = st where business = o;
      update public.acc_entries set business = st where business = o;
      update public.acc_entries set to_business = st where to_business = o;
      update public.acc_recurring set business = st where business = o;
      update public.invoices set business = st where business = o;
      update public.places set business = st where business = o;
      update public.payments set fee_business = st where fee_business = o;
      update public.packages set acc_business = st where acc_business = o;
      update public.shop_categories set acc_business = st where acc_business = o;
      update public.shop_locations set acc_business = st where acc_business = o;
      update public.app_settings set value = replace(value, '"' || o || '"', to_jsonb(st)::text) where key in ('acc_structure','invoice_template') and value like '%' || o || '%';
      update public.acc_recurring set split = replace(split::text, '"' || o || '"', to_jsonb(st)::text)::jsonb where split::text like '%' || o || '%';
    end if;
  end loop;
end $$;

-- the app reads the names with the structure
create or replace function public.acc_names() returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('main', private.biz_main(), 'stay', private.biz_stay())
$$;
revoke all on function public.acc_names() from public, anon;
grant execute on function public.acc_names() to authenticated;
