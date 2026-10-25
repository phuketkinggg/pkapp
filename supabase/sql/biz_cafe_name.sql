-- The cafe department is named per install too: app_settings 'acc_names' key "cafe" (Phuket King: Pangea Cafe).
create or replace function private.dept_cafe() returns text language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim((select case when value ~ '^\s*\{' then value::jsonb->>'cafe' end from public.app_settings where key = 'acc_names')), ''), 'Pangea Cafe')
$$;
revoke all on function private.dept_cafe() from public, anon;
grant execute on function private.dept_cafe() to authenticated;

do $$
declare c text := private.dept_cafe(); r record; s text; o text; n int := 0;
begin
  for r in select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where ns.nspname in ('public','private') and p.prokind = 'f' and p.proname <> 'dept_cafe'
             and p.prosrc ~ '''(Pangea Cafe|Fight Cafe|Tea Corner)''' loop
    s := pg_get_functiondef(r.oid);
    foreach o in array array['Pangea Cafe','Fight Cafe','Tea Corner', c] loop s := replace(s, '''' || o || '''', 'private.dept_cafe()'); end loop;
    s := replace(s, E'\n IMMUTABLE', E'\n STABLE');
    execute s; n := n + 1;
  end loop;
  raise notice 'functions changed: %', n;
  foreach o in array array['Pangea Cafe','Fight Cafe','Tea Corner'] loop
    if o <> c then
      update public.expense_receipts set department = c where department = o;
      update public.acc_entries set department = c where department = o;
      update public.acc_recurring set department = c where department = o;
      update public.invoices set department = c where department = o;
      update public.packages set acc_department = c where acc_department = o;
      update public.shop_categories set acc_department = c where acc_department = o;
      update public.shop_locations set acc_department = c where acc_department = o;
      update public.app_settings set value = replace(value, '"' || o || '"', to_jsonb(c)::text) where key = 'acc_structure' and value like '%' || o || '%';
      update public.acc_recurring set split = replace(split::text, '"' || o || '"', to_jsonb(c)::text)::jsonb where split::text like '%' || o || '%';
    end if;
  end loop;
end $$;

create or replace function public.acc_names() returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('main', private.biz_main(), 'stay', private.biz_stay(), 'cafe', private.dept_cafe())
$$;
