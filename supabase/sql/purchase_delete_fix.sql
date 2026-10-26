-- Fix: deleting a paid package as a mistake failed with "tuple to be deleted was already modified".
-- Deleting a package voids its payments first, and the payment trigger then tried to update the paid amount
-- on the very package being deleted. The delete now marks the package, and the payment trigger leaves it alone.
do $$ declare s text;
begin
  s := pg_get_functiondef('private.void_payments_on_delete()'::regprocedure);
  if s not like '%pk.del_purchase%' then
    s := replace(s, $a$  if tg_table_name = 'purchases' then update public.payments$a$, $a$  if tg_table_name = 'purchases' then perform set_config('pk.del_purchase', old.id::text, true); update public.payments$a$);
    if s not like '%pk.del_purchase%' then raise notice 'void_payments_on_delete is a different version here: skipped.'; else execute s; end if;
  end if;
  s := pg_get_functiondef('private.payments_after()'::regprocedure);
  if s not like '%pk.del_purchase%' then
    s := replace(s, $a$  if pid is not null then$a$, $a$  if pid is not null and coalesce(current_setting('pk.del_purchase', true), '') <> pid::text then$a$);
    if s not like '%pk.del_purchase%' then raise notice 'payments_after is a different version here: skipped.'; else execute s; end if;
  end if;
end $$;
