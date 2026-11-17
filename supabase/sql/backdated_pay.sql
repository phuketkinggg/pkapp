-- Sales entered late (feature backdated_pay, on unless switched off): a package added today with an earlier "bought" date,
-- and paid when it is added (cash, transfer, QR, take payment), counts in the accounts on the day it was bought, not today.
-- Only for packages added today: a package added back then and paid now still counts today.
create or replace function private.payment_backdate() returns trigger language plpgsql security definer set search_path to '' as $f$
declare k public.purchases; t date := private.bkk_today();
begin
  if new.purchase_id is null or new.day is distinct from t or not private.feature('backdated_pay', true) then return new; end if;
  select * into k from public.purchases where id = new.purchase_id;
  if k.id is null or k.purchased_on is null or k.purchased_on >= t then return new; end if;
  if (k.created_at at time zone private.tz())::date <> t then return new; end if;
  new.day := k.purchased_on;
  return new;
end $f$;
revoke all on function private.payment_backdate() from public, anon, authenticated;
drop trigger if exists payment_backdate on public.payments;
create trigger payment_backdate before insert on public.payments for each row execute function private.payment_backdate();
