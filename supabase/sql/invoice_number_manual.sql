-- Invoices: the invoice number can be typed by hand (new or not yet paid invoices). It must be a whole number not used by another invoice.
-- Empty = the next number as before.
do $$ declare s text;
begin
  s := pg_get_functiondef('public.invoice_save(jsonb)'::regprocedure);
  if s like '%number is already used%' then return; end if;
  s := replace(s, '  if v_id is null then', $a$  if nullif(trim(p->>'number'),'') is not null then
    if trim(p->>'number') !~ '^[0-9]{1,9}$' or trim(p->>'number')::int < 1 then raise exception 'The invoice number must be a whole number, like 1052.'; end if;
    if exists (select 1 from public.invoices x where x.number = trim(p->>'number')::int and x.id is distinct from v_id) then raise exception 'Invoice number % is already used.', trim(p->>'number'); end if;
  end if;
  if v_id is null then$a$);
  s := replace(s, 'select coalesce(max(number), 0) + 1 into n from public.invoices;', $a$select coalesce(max(number), 0) + 1 into n from public.invoices;
    if nullif(trim(p->>'number'),'') is not null then n := trim(p->>'number')::int; end if;$a$);
  s := replace(s, $a$status = case when status = 'cancelled' then 'unpaid' else status end, updated_at = now()$a$, $a$number = coalesce(nullif(trim(p->>'number'),'')::int, number), status = case when status = 'cancelled' then 'unpaid' else status end, updated_at = now()$a$);
  if s not like '%number is already used%' or s not like '%n := trim(p->>''number'')::int%' or s not like '%number = coalesce(nullif(trim(p->>''number''),'''')::int, number)%' then raise notice 'invoice_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;
