-- Fix: making an invoice failed with 'column reference "items" is ambiguous' (a variable had the same name as the column).
do $$ declare s text;
begin
  s := pg_get_functiondef('public.invoice_save(jsonb)'::regprocedure);
  if s like '%v_items%' then return; end if;
  s := replace(s, $a$items jsonb := '[]'::jsonb$a$, $a$v_items jsonb := '[]'::jsonb$a$);
  s := replace(s, 'items := items || ', 'v_items := v_items || ');
  s := replace(s, 'jsonb_array_length(items)', 'jsonb_array_length(v_items)');
  s := replace(s, 'items = items,', 'items = v_items,');
  if (length(s) - length(replace(s, 'v_items', ''))) / 7 < 5 then raise notice 'invoice_save is a different version here: skipped.'; return; end if;
  execute s;
end $$;
