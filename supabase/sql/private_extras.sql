-- Extras on a private (feature: private_extras). A booking often brings more than the private itself, for example
-- a GetYourGuide private with ice bath and sauna, a meal or a second person. The desk types the private amount
-- (the coach share is worked out from it only) and each extra with its amount and department (Spa, cafe, gym shop).
-- privates.price_thb stays the whole amount received, so bills and payments do not change.
-- privates.adds = [{name, thb, dept}], privates.adds_thb = their total (kept by a trigger).
-- Accounts split each private payment: the private part to Privates, each extra to its own department.
alter table public.privates add column if not exists adds jsonb not null default '[]'::jsonb;
alter table public.privates add column if not exists adds_thb int not null default 0;

create or replace function private.privates_adds() returns trigger language plpgsql set search_path to '' as $f$
declare clean jsonb := '[]'::jsonb; e jsonb; tot int := 0; n text; v int;
begin
  if jsonb_typeof(coalesce(new.adds, '[]'::jsonb)) <> 'array' then new.adds := '[]'::jsonb; end if;
  for e in select * from jsonb_array_elements(coalesce(new.adds, '[]'::jsonb)) limit 20 loop
    n := nullif(left(btrim(coalesce(e->>'name', '')), 60), '');
    v := round(coalesce(nullif(e->>'thb', '')::numeric, 0))::int;
    if n is null or v <= 0 then continue; end if;
    clean := clean || jsonb_build_array(jsonb_build_object('name', n, 'thb', v, 'dept', nullif(left(btrim(coalesce(e->>'dept', '')), 40), '')));
    tot := tot + v;
  end loop;
  new.adds := clean; new.adds_thb := tot;
  if tot > 0 and tot > coalesce(new.price_thb, 0) - coalesce(new.fee_thb, 0) - coalesce(new.tax_thb, 0) then
    raise exception 'The extras come to more than the total received. Check the amounts.';
  end if;
  return new;
end $f$;
drop trigger if exists privates_adds on public.privates;
create trigger privates_adds before insert or update on public.privates for each row execute function private.privates_adds();

-- a private already in a coach payout keeps its extras too
do $$ declare d text; begin
  select pg_get_functiondef('private.privates_payout_lock()'::regprocedure) into d;
  if d is null then raise notice 'privates_payout_lock: not here, skipped'; return; end if;
  if position('adds_thb' in d) > 0 then raise notice 'privates_payout_lock: already done'; return; end if;
  d := replace(d, 'or new.coach_id is distinct from old.coach_id', 'or new.coach_id is distinct from old.coach_id or new.adds_thb is distinct from old.adds_thb');
  if position('adds_thb' in d) = 0 then raise exception 'privates_payout_lock: patch did not apply'; end if;
  execute d;
exception when undefined_function then raise notice 'privates_payout_lock: not here, skipped';
end $$;

-- coach share: from the private amount only, never the extras
do $$ declare f text; d text; n int := 0; begin
  foreach f in array array['public.private_team','public.commission_pay','public.coach_home'] loop
    begin
      select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname || '.' || p.proname = f limit 1;
      if d is null then raise notice '%: not here, skipped', f; continue; end if;
      if position('adds_thb' in d) > 0 then raise notice '%: already done', f; continue; end if;
      d := regexp_replace(d, '\+ coalesce\((\w+)\.extra_thb, ?0\)', '+ coalesce(\1.extra_thb, 0) - coalesce(\1.adds_thb, 0)', 'g');
      if position('adds_thb' in d) = 0 then raise notice '%: older version without the share formula, skipped', f; continue; end if;
      execute d; n := n + 1;
    end;
  end loop;
  raise notice 'coach share patched in % functions', n;
end $$;

-- receipts: the private and each extra on its own line
do $$ declare d text; begin
  select pg_get_functiondef('public.receipt_view'::regproc) into d;
  if position('adds_thb' in d) > 0 then raise notice 'receipt_view: already done'; return; end if;
  d := replace(d, $r$'amount', coalesce(pv.price_thb, 0) - fee - tax));$r$,
    $r$'amount', coalesce(pv.price_thb, 0) - fee - tax - coalesce(pv.adds_thb, 0)));
    lines := lines || coalesce((select jsonb_agg(jsonb_build_object('name', e->>'name', 'amount', (e->>'thb')::numeric)) from jsonb_array_elements(coalesce(pv.adds, '[]'::jsonb)) e), '[]'::jsonb);$r$);
  if position('adds_thb' in d) = 0 then raise notice 'receipt_view: older version, skipped'; return; end if;
  execute d;
exception when undefined_function or undefined_object then raise notice 'receipt_view: not here, skipped';
end $$;

-- accounts: each private payment is split, the extras go to their own departments
do $$ declare d text; begin
  select pg_get_functiondef('private.acc_lines(date,date)'::regprocedure) into d;
  if position('pv.adds' in d) > 0 then raise notice 'acc_lines: already done'; return; end if;
  d := replace(d, $r$cross join lateral (values ('main', p.amount_thb - w.f - w.t), ('fee', w.f), ('tax', w.t)) x(part, amt)$r$,
    $r$cross join lateral (select coalesce(jsonb_agg(jsonb_build_object('n', e->>'name', 'd', e->>'dept', 'a', case when z.pr > 0 then round(p.amount_thb::numeric * (e->>'thb')::numeric / z.pr) else 0 end)), '[]'::jsonb) l
      from jsonb_array_elements(case when pv.id is not null and jsonb_typeof(pv.adds) = 'array' then pv.adds else '[]'::jsonb end) e) ad
    cross join lateral (select 'main'::text part, p.amount_thb - w.f - w.t - coalesce((select sum((y->>'a')::numeric) from jsonb_array_elements(ad.l) y), 0) amt, null::text xd, null::text xn
      union all select 'fee', w.f, null, null union all select 'tax', w.t, null, null
      union all select 'add', (y->>'a')::numeric, nullif(y->>'d', ''), y->>'n' from jsonb_array_elements(ad.l) y) x$r$);
  d := replace(d, $r$select p.day, coalesce(p.fee_business,$r$,
    $r$select p.day, coalesce(case when x.part = 'add' then case when x.xd = private.dept_cafe() then private.biz_cafe() when x.xd = 'Tours' then private.biz_tours() else private.biz_main() end end, p.fee_business,$r$);
  d := replace(d, $r$case when p.is_fee then coalesce(p.fee_dept, 'Card fees')$r$, $r$case when x.part = 'add' then coalesce(x.xd, 'Other') when p.is_fee then coalesce(p.fee_dept, 'Card fees')$r$);
  d := replace(d, $r$when p.private_id is not null then 'Private' else$r$, $r$when x.part = 'add' then 'Private extra: ' || coalesce(x.xn, 'extra') when p.private_id is not null then 'Private' else$r$);
  if position('pv.adds' in d) = 0 or position($r$x.part = 'add' then coalesce(x.xd$r$ in d) = 0 or position('Private extra' in d) = 0 or position($r$x.xd = 'Tours'$r$ in d) = 0 then
    raise notice 'acc_lines: older version, skipped'; return; end if;
  execute d;
exception when undefined_function then raise notice 'acc_lines: not here, skipped';
end $$;
notify pgrst, 'reload schema';
