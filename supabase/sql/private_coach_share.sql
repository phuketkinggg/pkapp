-- Coach pay set per private: privates.coach_share_thb. Empty: the coach's usual percent of the private. Set: exactly this amount
-- (for example 2 people for 1,400 THB, the coach gets 600). Used by commission, payouts and the coach's own screen.
alter table public.privates add column if not exists coach_share_thb int check (coach_share_thb is null or coach_share_thb between 0 and 1000000);

do $$ declare s text;
begin
  s := pg_get_functiondef('public.commission_pay(uuid,date,date,text)'::regprocedure);
  if s not like '%coach_share_thb%' then
    s := replace(s, $a$sum(round((coalesce(p.price_thb,0) - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0)) * coalesce(p.coach_pct,50) / 100.0))::int share$a$,
                    $a$sum(coalesce(p.coach_share_thb, round((coalesce(p.price_thb,0) - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0)) * coalesce(p.coach_pct,50) / 100.0)))::int share$a$);
    s := replace(s, $a$'share', round((coalesce(p.price_thb,0) - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0)) * coalesce(p.coach_pct,50) / 100.0)::int,$a$,
                    $a$'share', coalesce(p.coach_share_thb, round((coalesce(p.price_thb,0) - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0)) * coalesce(p.coach_pct,50) / 100.0))::int, 'set_share', p.coach_share_thb is not null,$a$);
    if (length(s) - length(replace(s, 'coach_share_thb', ''))) / length('coach_share_thb') < 3 then raise exception 'commission_pay patch did not apply'; end if;
    execute s;
  end if;
  s := pg_get_functiondef('public.coach_home()'::regprocedure);
  if s not like '%coach_share_thb%' then
    s := replace(s, $a$'share_thb', round((p.price_thb - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0)) * p.coach_pct / 100.0),$a$,
                    $a$'share_thb', coalesce(p.coach_share_thb, round((p.price_thb - p.fee_thb - p.tax_thb + coalesce(p.extra_thb,0)) * p.coach_pct / 100.0)),$a$);
    if s not like '%coach_share_thb%' then raise exception 'coach_home patch did not apply'; end if;
    execute s;
  end if;
  -- a private already paid out keeps its share
  s := pg_get_functiondef('private.privates_payout_lock()'::regprocedure);
  if s not like '%coach_share_thb%' then
    s := replace(s, $a$or new.coach_pct is distinct from old.coach_pct$a$, $a$or new.coach_pct is distinct from old.coach_pct or new.coach_share_thb is distinct from old.coach_share_thb$a$);
    if s not like '%coach_share_thb%' then raise exception 'privates_payout_lock patch did not apply'; end if;
    execute s;
  end if;
end $$;
