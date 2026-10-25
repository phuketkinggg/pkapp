-- Everyone on the team can add a receipt, even an admin with view only access.
-- Changing or removing receipts still needs Change things (and remove needs admin or owner).
do $$ declare s text;
begin
  s := pg_get_functiondef('private.guard_view_only()'::regprocedure);
  if s not like '%expense_receipts%' then
    s := replace(s, $a$  if (select auth.uid()) is not null and exists$a$, $a$  -- adding a receipt is open to everyone on the team
  if tg_table_name = 'expense_receipts' and tg_op = 'INSERT' then return new; end if;
  if (select auth.uid()) is not null and exists$a$);
    if s not like '%expense_receipts%' then raise exception 'guard_view_only patch did not apply'; end if;
    execute s;
  end if;
end $$;
