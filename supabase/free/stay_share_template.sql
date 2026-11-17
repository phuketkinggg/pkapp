delete from mf.template where name like 'stay_share:%';
insert into mf.template (ord, phase, kind, name, sql) values (303531, 3, 'patch', 'stay_share:303531', $TPL$alter table __P__.stays add column if not exists guest_ids uuid[] not null default '{}';$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002231, 10, 'patch', 'stay_share:1002231', $TPL$create index if not exists stays_guest_ids_idx on __P__.stays using gin (guest_ids);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403671, 4, 'patch', 'stay_share:403671', $TPL$create or replace function __P__.stay_share(p_stay uuid, p_customer uuid, p_on boolean) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare s __P__.stays; nm text;
begin
  if not __Q__.is_desk() then raise exception 'Only the team can do this.'; end if;
  select * into s from __P__.stays where id = p_stay;
  if s.id is null then raise exception 'That stay was not found.'; end if;
  if s.customer_id = p_customer then raise exception 'The stay is already under their name.'; end if;
  select name into nm from __P__.customers where id = p_customer;
  if nm is null then raise exception 'That customer was not found.'; end if;
  if p_on then
    update __P__.stays set guest_ids = (select array_agg(distinct x) from unnest(guest_ids || p_customer) x),
      guest_names = case when lower(btrim(nm)) in (select lower(btrim(x)) from regexp_split_to_table(coalesce(guest_names, ''), E'\n|,') x) then guest_names
        else btrim(coalesce(nullif(btrim(guest_names), ''), (select c.name from __P__.customers c where c.id = s.customer_id), '') || E'\n' || btrim(nm)) end
      where id = p_stay;
  else
    update __P__.stays set guest_ids = array_remove(guest_ids, p_customer) where id = p_stay;
  end if;
  return jsonb_build_object('ok', true);
end $f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197671, 11, 'patch', 'stay_share:1197671', $TPL$revoke all on function __P__.stay_share(uuid, uuid, boolean) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197672, 11, 'patch', 'stay_share:1197672', $TPL$grant execute on function __P__.stay_share(uuid, uuid, boolean) to authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1002232, 10, 'patch', 'stay_share:1002232', $TPL$do $p$
declare r record; d text; n text; f oid;
begin
  for r in select * from (values
    ('private', 'charge_purchase_to_room', 's.customer_id = new.customer_id and s.status', '(s.customer_id = new.customer_id or new.customer_id = any(s.guest_ids)) and s.status'),
    ('private', 'private_room_charge', 's.customer_id = new.customer_id and s.status', '(s.customer_id = new.customer_id or new.customer_id = any(s.guest_ids)) and s.status'),
    ('public', 'customer_private_pay', 's.customer_id = c.id and s.status', '(s.customer_id = c.id or c.id = any(s.guest_ids)) and s.status'),
    ('public', 'customer_stay', 's.customer_id = v_customer and s.status', '(s.customer_id = v_customer or v_customer = any(s.guest_ids)) and s.status'),
    ('public', 'customer_stay_as', 's.customer_id = v_customer and s.status', '(s.customer_id = v_customer or v_customer = any(s.guest_ids)) and s.status'),
    ('public', 'shop_app_order', 'where customer_id = me_c and status', 'where (customer_id = me_c or me_c = any(guest_ids)) and status')
  ) v(sch, fn, a, b) loop
    for f in select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = r.sch and p.proname = r.fn loop
      d := pg_get_functiondef(f);
      if position('guest_ids' in d) > 0 then raise notice 'stay_share: %.% already done', r.sch, r.fn; continue; end if;
      if position(r.a in d) = 0 then raise notice 'stay_share: %.% is a different version here, skipped', r.sch, r.fn; continue; end if;
      n := replace(d, r.a, r.b);
      execute n;
      if position('guest_ids' in pg_get_functiondef(f)) = 0 then raise exception 'stay_share: %.% did not patch', r.sch, r.fn; end if;
    end loop;
  end loop;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'stay_share:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
