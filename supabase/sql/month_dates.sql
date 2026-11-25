-- Month packages end on the same date (feature month_dates, on by default).
-- A package valid for a whole number of months (30 days is 1 month, 91 is 3, 182 is 6, 274 is 9, 365 is 12, 1826 is 5 years)
-- used to end start + days - 1: started 26 Oct, ended 24 Nov. Now it ends on the same date: started 26 Oct, ends 26 Nov.
-- Only an end date worked out from the length is changed: dates set by hand, moved by a pause, or tied to a stay stay as they are.

create or replace function private.month_count(p_days int) returns int language sql immutable set search_path = '' as $f$
  select case when p_days >= 28 and abs(p_days - round(p_days / 30.4375) * 30.4375) <= 3.5 then round(p_days / 30.4375)::int end
$f$;

create or replace function private.month_dates() returns trigger language plpgsql set search_path = '' as $f$
declare m int;
begin
  if new.starts_on is null or new.expires_on is null or new.duration_days is null then return new; end if;
  if new.stay_id is not null or coalesce(new.for_stay, false) then return new; end if;
  if new.expires_on <> new.starts_on + new.duration_days - 1 then return new; end if;
  if tg_op = 'UPDATE' and old.starts_on is not distinct from new.starts_on and old.expires_on is not distinct from new.expires_on
     and old.duration_days is not distinct from new.duration_days then return new; end if;
  m := private.month_count(new.duration_days);
  if m is null or not private.feature('month_dates', true) then return new; end if;
  new.expires_on := (new.starts_on + make_interval(months => m))::date;
  return new;
end $f$;
revoke all on function private.month_count(int), private.month_dates() from public, anon, authenticated;

drop trigger if exists purchases_month_dates on public.purchases;
create trigger purchases_month_dates before insert or update of starts_on, expires_on, duration_days on public.purchases
  for each row execute function private.month_dates();

-- packages running now: move the end to the same date too (only ones still on the worked-out end, never shorter)
update public.purchases p set expires_on = (p.starts_on + make_interval(months => private.month_count(p.duration_days)))::date
where private.feature('month_dates', true) and not coalesce(p.cancelled, false) and p.refunded_at is null
  and p.stay_id is null and not coalesce(p.for_stay, false)
  and p.starts_on is not null and p.duration_days is not null and private.month_count(p.duration_days) is not null
  and p.expires_on = p.starts_on + p.duration_days - 1 and p.expires_on >= (now() at time zone 'Asia/Bangkok')::date
  and (p.starts_on + make_interval(months => private.month_count(p.duration_days)))::date > p.expires_on;
