-- Invoices: change the number from the invoice itself, at any time (also once it is paid). Manager only, must not be used by another invoice.
create or replace function public.invoice_set_number(p_id uuid, p_number integer) returns jsonb language plpgsql security definer set search_path to '' as $$
declare o public.invoices;
begin
  if not private.can('money') or coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change invoice numbers.'; end if;
  if p_number is null or p_number < 1 or p_number > 999999999 then raise exception 'The invoice number must be a whole number, like 1052.'; end if;
  if exists (select 1 from public.invoices x where x.number = p_number and x.id <> p_id) then raise exception 'Invoice number % is already used.', p_number; end if;
  update public.invoices set number = p_number, updated_at = now() where id = p_id returning * into o;
  if o.id is null then raise exception 'Invoice not found.'; end if;
  return private.inv_json(o);
end $$;
revoke all on function public.invoice_set_number(uuid, integer) from public, anon;
grant execute on function public.invoice_set_number(uuid, integer) to authenticated;
