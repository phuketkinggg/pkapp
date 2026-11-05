delete from mf.template where name like 'stay_refund:%';
insert into mf.template (ord, phase, kind, name, sql) values (401201, 4, 'patch', 'stay_refund:401201', $TPL$create or replace function __Q__.stay_room_refundable(p_stay uuid) returns integer
language sql stable security definer set search_path to '' as $q$
  -- room money taken on this stay (deposits, paid ahead, the settled bill), less extras charged to a settled bill (those refund on the add-on)
  select greatest(0,
    coalesce((select sum(amount_thb) from __P__.payments where stay_id = p_stay and purchase_id is null and private_id is null and not voided and not coalesce(is_fee, false)), 0)
    - coalesce((select sum(rc.amount_thb) from __P__.room_charges rc join __P__.stays s on s.id = rc.stay_id
                where rc.stay_id = p_stay and s.settled and not rc.voided and (rc.purchase_id is not null or rc.private_id is not null)), 0))::int
$q$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401202, 4, 'patch', 'stay_refund:401202', $TPL$create or replace function __P__.stay_refund_info(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $q$
declare s __P__.stays%rowtype;
begin
  if not __Q__.is_desk() then raise exception 'Not allowed.'; end if;
  select * into s from __P__.stays where id = p_stay; if s.id is null then raise exception 'That stay is not there any more.'; end if;
  return jsonb_build_object(
    'room', __Q__.stay_room_refundable(p_stay),
    'status', s.status,
    'stripe', (select stripe_session from __P__.payments p where not p.voided and p.amount_thb > 0 and p.stripe_session is not null
                 and (p.stay_id = p_stay or p.purchase_id in (select id from __P__.purchases where for_stay = p_stay or stay_id = p_stay))
               order by p.at desc limit 1),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.package_name, 'paid', __Q__.refundable(k.id, null)) order by k.created_at)
       from __P__.purchases k where (k.for_stay = p_stay or k.stay_id = p_stay) and k.refunded_at is null
         and k.package_name <> 'Stay: group Muay Thai included' and __Q__.refundable(k.id, null) > 0), '[]'::jsonb));
end $q$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (401203, 4, 'patch', 'stay_refund:401203', $TPL$create or replace function __P__.refund_stay(p_stay uuid, p_room integer, p_extras jsonb, p_method text, p_pin text, p_reason text, p_cancel boolean, p_dry boolean default false, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $q$
declare s __P__.stays%rowtype; who uuid; why text := btrim(coalesce(p_reason,'')); mx integer; room integer := coalesce(p_room, 0);
  x jsonb; k __P__.purchases%rowtype; a integer; total integer := 0; meth text := coalesce(nullif(p_method,''),'cash'); cn text; tag text;
begin
  if not __Q__.is_desk() then raise exception 'Not allowed.'; end if;
  who := __Q__.manager_pin(p_pin);
  if why = '' then raise exception 'Say why it is refunded.'; end if;
  select * into s from __P__.stays where id = p_stay for update; if s.id is null then raise exception 'That stay is not there any more.'; end if;
  mx := __Q__.stay_room_refundable(p_stay);
  if room < 0 or room > mx then raise exception 'You can give back up to % THB on the room.', mx; end if;
  -- check every add-on first
  for x in select * from jsonb_array_elements(coalesce(p_extras, '[]'::jsonb)) loop
    select * into k from __P__.purchases where id = (x->>'id')::uuid for update;
    if k.id is null or not (k.for_stay = p_stay or k.stay_id = p_stay) then raise exception 'That add-on is not on this stay.'; end if;
    if k.refunded_at is not null then raise exception '% was already refunded.', k.package_name; end if;
    a := coalesce((x->>'amount')::int, 0); mx := greatest(__Q__.refundable(k.id, null), 0);
    if a < 0 or a > mx then raise exception 'You can give back up to % THB on %.', mx, k.package_name; end if;
    total := total + a;
  end loop;
  total := total + room;
  if total = 0 and not coalesce(p_cancel, false) then raise exception 'Nothing to refund. Type an amount, or tick Cancel the stay.'; end if;
  if p_dry then return jsonb_build_object('ok', true, 'total', total); end if;

  tag := 'Refund: ' || why || coalesce(' (' || nullif(btrim(coalesce(p_note,'')), '') || ')', '');
  if room > 0 then perform __Q__.pay_insert(s.customer_id, null, null, p_stay, -room, meth, __Q__.bkk_today(), tag); end if;
  for x in select * from jsonb_array_elements(coalesce(p_extras, '[]'::jsonb)) loop
    select * into k from __P__.purchases where id = (x->>'id')::uuid; a := coalesce((x->>'amount')::int, 0);
    if a > 0 then perform __Q__.pay_insert(k.customer_id, k.id, null, null, -a, meth, __Q__.bkk_today(), tag); end if;
    update __P__.room_charges rc set amount_thb = 0, voided = true, void_note = 'Refunded: ' || why
      where rc.purchase_id = k.id and not rc.voided and not exists (select 1 from __P__.stays t where t.id = rc.stay_id and t.settled);
    update __P__.privates set status = 'cancelled' where purchase_id = k.id and date >= __Q__.bkk_today() and status in ('confirmed','requested');
    update __P__.purchases set cancelled = true, refunded_at = now(), refund_thb = a, refund_reason = why, refunded_by = who where id = k.id;
  end loop;
  if coalesce(p_cancel, false) and s.status <> 'cancelled' then
    update __P__.stays set status = 'cancelled', hold_until = null,
      notes = btrim(coalesce(notes, '') || E'\n' || 'Cancelled ' || to_char(__Q__.bkk_today(), 'DD Mon YYYY') || ': ' || why || case when total > 0 then ', refunded ' || to_char(total, 'FM999,999,990') || ' THB' else '' end)
    where id = p_stay;
  end if;
  select name into cn from __P__.customers where id = s.customer_id;
  insert into __P__.notices (kind, customer_id, ref_id, title, detail)
  values ('refund', s.customer_id, p_stay, 'Refund: stay' || case when coalesce(p_cancel,false) then ' cancelled' else '' end || ', ' || coalesce(cn, 'a guest'),
          to_char(total, 'FM999,999,990') || ' THB back. ' || why);
  return jsonb_build_object('refunded', total);
end $q$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103701, 11, 'patch', 'stay_refund:1103701', $TPL$revoke all on function __P__.refund_stay(uuid,integer,jsonb,text,text,text,boolean,boolean,text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103702, 11, 'patch', 'stay_refund:1103702', $TPL$grant execute on function __P__.refund_stay(uuid,integer,jsonb,text,text,text,boolean,boolean,text) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103703, 11, 'patch', 'stay_refund:1103703', $TPL$revoke all on function __P__.stay_refund_info(uuid) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103704, 11, 'patch', 'stay_refund:1103704', $TPL$grant execute on function __P__.stay_refund_info(uuid) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1103705, 11, 'patch', 'stay_refund:1103705', $TPL$revoke all on function __Q__.stay_room_refundable(uuid) from public, anon, authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'stay_refund:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
