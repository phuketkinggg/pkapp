-- Cancel a private, or mark a no show, with a reason (feature private_cancel, on unless switched off). The desk or a manager chooses:
-- still paid: it counts like a session that happened (a pack session is used, or the price stays owed, and the coach is paid as usual),
-- shown as cancelled or no show with the reason; not paid: it is cancelled (a pack session comes back, nothing is owed).
-- A group private cancels with everyone in it.

alter table public.privates add column if not exists cancel_kind text check (cancel_kind in ('cancelled','no_show'));
alter table public.privates add column if not exists cancel_reason text;
alter table public.privates add column if not exists cancel_charged boolean;
alter table public.privates add column if not exists cancelled_at timestamptz;
alter table public.privates add column if not exists cancelled_by uuid;
grant select (cancel_kind, cancel_reason, cancel_charged, cancelled_at, cancelled_by) on public.privates to authenticated;

create or replace function public.private_cancel(p_id uuid, p_kind text, p_reason text, p_charged boolean) returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare p public.privates; why text := left(btrim(coalesce(p_reason, '')), 300); n int; had_paid int;
begin
  if not private.feature('private_cancel', true) then raise exception 'Switched off in Settings, Features.'; end if;
  if not private.is_desk() then raise exception 'Only the front desk or a manager can do this.'; end if;
  if p_kind not in ('cancelled','no_show') then raise exception 'Choose cancelled or no show.'; end if;
  if why = '' then raise exception 'Say why.'; end if;
  select * into p from public.privates where id = p_id for update;
  if p.id is null then raise exception 'That private was not found.'; end if;
  if p.lead_id is not null then select * into p from public.privates where id = p.lead_id for update; end if;
  if p.status in ('requested') then raise exception 'This one is still a request. Decline it instead.'; end if;
  if p.status = 'cancelled' and p.cancel_kind is null then raise exception 'It is already cancelled.'; end if;
  had_paid := case when p.paid and p.purchase_id is null and not coalesce(p_charged, false) then coalesce(p.price_thb, 0) else 0 end;
  update public.privates set
      status = case when coalesce(p_charged, false) then 'done' else 'cancelled' end,
      cancel_kind = p_kind, cancel_reason = why, cancel_charged = coalesce(p_charged, false), cancelled_at = now(), cancelled_by = private.my_staff_id()
    where id = p.id or lead_id = p.id;
  get diagnostics n = row_count;
  return jsonb_build_object('rows', n, 'charged', coalesce(p_charged, false), 'paid_before', had_paid);
end $f$;
revoke all on function public.private_cancel(uuid, text, text, boolean) from public, anon;
grant execute on function public.private_cancel(uuid, text, text, boolean) to authenticated;

notify pgrst, 'reload schema';
