-- Website room booking: pay a deposit instead of the whole stay (Settings, Website offer).
-- The book function works out the amount to pay now and writes it on the stay (web_pay_now_thb).
-- A Thai QR claim asks for that amount, and the booking status tells the page about it.
alter table public.stays add column if not exists web_pay_now_thb integer;

do $p$
declare d text; n text;
begin
  -- the Thai QR claim: the amount to pay now (the deposit) when there is one
  select pg_get_functiondef('public.web_stay_claim(uuid)'::regprocedure) into d;
  if position('web_pay_now_thb' in d) > 0 then raise notice 'web_stay_claim already patched';
  elsif position('amt := private.web_stay_total(s.id);' in d) = 0 then raise notice 'web_stay_claim: older version, skipped';
  else
    n := replace(d, 'amt := private.web_stay_total(s.id);', 'amt := coalesce(nullif(s.web_pay_now_thb, 0), private.web_stay_total(s.id));');
    execute n;
    if position('web_pay_now_thb' in pg_get_functiondef('public.web_stay_claim(uuid)'::regprocedure)) = 0 then raise exception 'web_stay_claim patch did not apply'; end if;
  end if;

  -- the booking status: the amount paid now, so the page can say deposit received and what is left
  select pg_get_functiondef('public.web_booking_status(uuid)'::regprocedure) into d;
  if position('pay_now' in d) > 0 then raise notice 'web_booking_status already patched';
  elsif position('''total'', private.web_stay_total(s.id),' in d) = 0 then raise notice 'web_booking_status: older version, skipped';
  else
    n := replace(d, '''total'', private.web_stay_total(s.id),', '''total'', private.web_stay_total(s.id), ''pay_now'', s.web_pay_now_thb, ''paid_thb'', coalesce(s.app_paid_thb, 0),');
    execute n;
    if position('pay_now' in pg_get_functiondef('public.web_booking_status(uuid)'::regprocedure)) = 0 then raise exception 'web_booking_status patch did not apply'; end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
