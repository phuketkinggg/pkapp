-- Charge to room for guests who paid their room in advance.
-- A stay paid in full (online, or a bill already settled) was marked settled, so it disappeared from Charge to room.
-- Now a checked-in stay with nothing owed can still take charges: the first new charge opens the bill again,
-- without touching the payments already made.

create or replace function private.stay_chargeable(p_stay uuid) returns boolean language sql stable security definer set search_path = '' as $f$
  select exists (select 1 from public.stays s where s.id = p_stay and s.status = 'in' and (not s.settled or private.stay_due(s.id) <= 0))
$f$;

create or replace function private.stay_reopen(p_stay uuid) returns void language plpgsql security definer set search_path = '' as $f$
begin
  if not exists (select 1 from public.stays where id = p_stay and settled) then return; end if;
  perform set_config('pk.extend', '1', true);   -- keep the payments already made
  update public.stays set settled = false, settled_method = null, settled_on = null where id = p_stay;
  perform set_config('pk.extend', '', true);
end $f$;
revoke all on function private.stay_chargeable(uuid), private.stay_reopen(uuid) from public, anon, authenticated;

do $p$
declare d text; n text;
begin
  -- the till: list and sell
  if to_regprocedure('public.shop_catalog()') is not null then
    d := pg_get_functiondef('public.shop_catalog()'::regprocedure);
    if position('stay_chargeable' in d) = 0 then
      n := replace(d, 'where st.status = ''in'' and not st.settled) end);', 'where private.stay_chargeable(st.id)) end);');
      n := replace(n, 'where st.customer_id = me_c and st.status = ''in'' and not st.settled order by', 'where st.customer_id = me_c and private.stay_chargeable(st.id) order by');
      if n = d then raise notice 'room_charge_prepaid: shop_catalog is different, skipped'; else execute n; end if;
    end if;
  end if;
  if to_regprocedure('public.shop_sell(jsonb)') is not null then
    d := pg_get_functiondef('public.shop_sell(jsonb)'::regprocedure);
    if position('stay_reopen' in d) = 0 then
      n := replace(d, '    if st.id is null or st.status <> ''in'' or st.settled then raise exception ''Choose a guest who is staying now.''; end if;',
        '    if st.id is null or not private.stay_chargeable(st.id) then raise exception ''Choose a guest who is staying now.''; end if;
    perform private.stay_reopen(st.id);');
      if n = d then raise notice 'room_charge_prepaid: shop_sell is different, skipped'; else execute n; end if;
    end if;
  end if;
  -- guests ordering in the app, to their room
  if to_regprocedure('public.shop_app_order(jsonb)') is not null then
    d := pg_get_functiondef('public.shop_app_order(jsonb)'::regprocedure);
    if position('stay_reopen' in d) = 0 then
      n := replace(d, 'and status = ''in'' and not settled order by check_in desc limit 1;
    if st.id is null then raise exception ''Charging to a room works while you are staying with us. Choose pay at the counter.''; end if;',
        'and private.stay_chargeable(id) order by check_in desc limit 1;
    if st.id is null then raise exception ''Charging to a room works while you are staying with us. Choose pay at the counter.''; end if;
    perform private.stay_reopen(st.id);');
      if n = d then raise notice 'room_charge_prepaid: shop_app_order is different, skipped'; else execute n; end if;
    end if;
  end if;
end $p$;

notify pgrst, 'reload schema';
