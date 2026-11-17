-- Website room booking: a guest who comes back while their room is still held (30 minutes) carries on with that same booking,
-- instead of a second booking being made (and the first one cancelled later). If they pick a different room or other dates,
-- their earlier unpaid hold is let go first, so the change works and they never block a room twice.
-- Patches public.web_reserve where it exists (the resort database); skips cleanly elsewhere or when already patched.

do $p$
declare d text; n text; anchor text := '  if (select count(*) from public.stays where hold_until > now()) >= 8 then';
begin
  if to_regprocedure('public.web_reserve(uuid,date,date,integer,text,text,text,text,text)') is null then raise notice 'web_reserve: not here, skipped'; return; end if;
  d := pg_get_functiondef('public.web_reserve(uuid,date,date,integer,text,text,text,text,text)'::regprocedure);
  if position('resumed' in d) > 0 then raise notice 'web_reserve: already carries on held bookings'; return; end if;
  if position(anchor in d) = 0 then raise notice 'web_reserve: a different version, skipped'; return; end if;
  n := replace(d, anchor, $b$  -- the same guest, same room and dates, still held and not paid: carry on with that booking
  select s.id into v_stay from public.stays s join public.customers c on c.id = s.customer_id
    where s.hold_until > now() and s.status = 'booked' and coalesce(s.app_paid_thb, 0) = 0 and lower(c.email) = v_email
      and s.room_id = p_room and s.check_in = p_from and s.check_out = p_to
    order by s.created_at desc limit 1;
  if v_stay is not null then
    update public.stays set hold_until = now() + interval '31 minutes', room_price_thb = p_price where id = v_stay;
    return jsonb_build_object('stay_id', v_stay, 'email', v_email, 'resumed', true);
  end if;
  -- a different room or other dates: their earlier unpaid hold is let go first
  update public.stays s set status = 'cancelled', hold_until = null, notes = coalesce(s.notes, '') || ' Changed on the website before paying.'
    from public.customers c
    where c.id = s.customer_id and s.hold_until > now() and s.status = 'booked' and coalesce(s.app_paid_thb, 0) = 0 and lower(c.email) = v_email;
$b$ || anchor);
  execute n;
  if position('resumed' in pg_get_functiondef('public.web_reserve(uuid,date,date,integer,text,text,text,text,text)'::regprocedure)) = 0 then
    raise exception 'web_reserve was not patched'; end if;
end $p$;
