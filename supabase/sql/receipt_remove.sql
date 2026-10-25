-- Receipts: everyone on the team adds them (who added it and when is kept). Only an admin or the owner removes one.
-- Removing keeps the receipt and photo, marks it removed, and records who removed it, when and why. It can be put back.

alter table public.expense_receipts add column if not exists removed_by uuid references public.staff(id) on delete set null;
alter table public.expense_receipts add column if not exists removed_at timestamptz;
alter table public.expense_receipts add column if not exists removed_why text;

-- admin or owner (staff_role maps admin to manager)
create or replace function private.receipt_boss() returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce(private.staff_role(), '') = 'manager'
$$;
revoke all on function private.receipt_boss() from public, anon, authenticated;

create or replace function public.receipt_remove(p_id uuid, p_why text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if not private.receipt_boss() then raise exception 'Only an admin or the owner can remove receipts.'; end if;
  update public.expense_receipts set status = 'removed', removed_by = private.my_staff_id(), removed_at = now(),
    removed_why = nullif(left(btrim(coalesce(p_why, '')), 200), '')
  where id = p_id and status <> 'removed';
  if not found then raise exception 'Receipt not found.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.receipt_remove(uuid, text) from public, anon;
grant execute on function public.receipt_remove(uuid, text) to authenticated;

create or replace function public.receipt_restore(p_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if not private.receipt_boss() then raise exception 'Only an admin or the owner can put receipts back.'; end if;
  update public.expense_receipts set status = 'new', removed_by = null, removed_at = null, removed_why = null
  where id = p_id and status = 'removed';
  if not found then raise exception 'Receipt not found.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.receipt_restore(uuid) from public, anon;
grant execute on function public.receipt_restore(uuid) to authenticated;

-- removed receipts in a period, for admin and owner
create or replace function public.receipts_removed(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
begin
  if not private.receipt_boss() then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'day', r.day, 'department', r.department, 'business', r.business, 'amount', r.amount_thb,
      'supplier', r.supplier, 'purpose', r.purpose, 'photo_path', r.photo_path, 'by', s.name, 'at', r.created_at,
      'removed_by', x.name, 'removed_at', r.removed_at, 'removed_why', r.removed_why) order by r.removed_at desc nulls last)
    from public.expense_receipts r left join public.staff s on s.id = r.staff_id left join public.staff x on x.id = r.removed_by
    where r.day between p_from and p_to and r.status = 'removed'), '[]'::jsonb);
end $$;
revoke all on function public.receipts_removed(date, date) from public, anon;
grant execute on function public.receipts_removed(date, date) to authenticated;

-- receipt_save can no longer remove (that goes through receipt_remove, so who removed it is kept)
do $$ declare s text;
begin
  s := pg_get_functiondef('public.receipt_save(jsonb)'::regprocedure);
  if s not like '%receipt_remove%' then
    s := replace(s, $a$  update public.expense_receipts set day$a$, $a$  if p->>'status' = 'removed' then raise exception 'Use Remove (receipt_remove) to remove a receipt.'; end if;
  update public.expense_receipts set day$a$);
    if s not like '%receipt_remove%' then raise exception 'receipt_save patch did not apply'; end if;
    execute s;
  end if;
end $$;
