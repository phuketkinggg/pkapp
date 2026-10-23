-- Monthly bills split between the businesses: a shared salary (maintenance, cleaners) can be, say, 60% Phuket King Gym and 40% Pangea Resort,
-- each part with its own department. Every month it posts one Money out line per business. Bills without a split work as before.
alter table public.acc_recurring add column if not exists split jsonb not null default '[]'::jsonb;
alter table public.acc_entries add column if not exists recurring_part smallint not null default 0;
drop index if exists public.acc_entries_recur;
create unique index if not exists acc_entries_recur2 on public.acc_entries (recurring_id, recurring_month, recurring_part) where recurring_id is not null;

create or replace function public.acc_recurring_save(p jsonb) returns uuid language plpgsql security definer set search_path to '' as $function$
declare v_id uuid := nullif(p->>'id','')::uuid; a numeric := nullif(p->>'amount','')::numeric; dm int := coalesce(nullif(p->>'day_of_month','')::int,1);
  sp jsonb := '[]'::jsonb; x jsonb; tot numeric := 0; biz text := p->>'business'; dep text := left(coalesce(p->>'department',''),60);
begin
  if not private.can('money') then raise exception 'Your access does not include money and accounts.'; end if;
  if coalesce(private.staff_role(),'') <> 'manager' then raise exception 'Only a manager can change the accounts.'; end if;
  if a is null or a < 0 then raise exception 'Type the amount.'; end if;
  if dm < 1 or dm > 28 then raise exception 'Pick a day from 1 to 28.'; end if;
  -- the split: each part a business, a department and a percent, adding up to 100
  if jsonb_typeof(p->'split') = 'array' and jsonb_array_length(p->'split') > 0 then
    if jsonb_array_length(p->'split') > 4 then raise exception 'Split between 4 at most.'; end if;
    for x in select * from jsonb_array_elements(p->'split') loop
      if coalesce(x->>'business','') not in ('Phuket King Gym','Pangea Resort') then raise exception 'Choose the business for each part of the split.'; end if;
      if coalesce(nullif(x->>'pct','')::numeric, 0) <= 0 then raise exception 'Each part of the split needs a percent above 0.'; end if;
      tot := tot + (x->>'pct')::numeric;
      sp := sp || jsonb_build_array(jsonb_build_object('business', x->>'business', 'department', left(coalesce(x->>'department',''),60), 'pct', round((x->>'pct')::numeric, 2)));
    end loop;
    if abs(tot - 100) > 0.01 then raise exception 'The split must add up to 100 percent (now % percent).', tot; end if;
    biz := sp->0->>'business'; dep := sp->0->>'department';
  end if;
  if coalesce(biz,'') not in ('Phuket King Gym','Pangea Resort') then raise exception 'Choose the business.'; end if;
  if v_id is null then
    insert into public.acc_recurring(kind,business,department,category,amount,method,party,note,day_of_month,from_month,active,created_by,split)
    values (case when p->>'kind'='in' then 'in' else 'out' end, biz, dep, left(coalesce(p->>'category',''),60), a,
      coalesce(nullif(p->>'method',''),'transfer'), left(coalesce(p->>'party',''),120), left(coalesce(p->>'note',''),300), dm,
      date_trunc('month', coalesce(nullif(p->>'from_month','')::date, private.bkk_today()))::date, coalesce((p->>'active')::boolean,true), private.my_staff_id(), sp) returning id into v_id;
  else
    update public.acc_recurring set kind=case when p->>'kind'='in' then 'in' else 'out' end, business=biz, department=dep,
      category=left(coalesce(p->>'category',''),60), amount=a, method=coalesce(nullif(p->>'method',''),'transfer'), party=left(coalesce(p->>'party',''),120), note=left(coalesce(p->>'note',''),300),
      day_of_month=dm, from_month=date_trunc('month', coalesce(nullif(p->>'from_month','')::date, from_month))::date, active=coalesce((p->>'active')::boolean,true), split=sp, updated_at=now() where id=v_id;
  end if;
  return v_id;
end $function$;

-- posting: a split bill makes one line per part (the last part takes any rounding), a month already posted the other way is left alone
create or replace function private.acc_post_recurring() returns integer language plpgsql security definer set search_path to '' as $function$
declare r public.acc_recurring; m date; t date := private.bkk_today(); n int := 0; x jsonb; i int; k int; done_amt numeric; amt numeric;
begin
  for r in select * from public.acc_recurring where active loop
    m := date_trunc('month', r.from_month)::date;
    k := jsonb_array_length(coalesce(r.split, '[]'::jsonb));
    while m <= date_trunc('month', t)::date loop
      if m + (r.day_of_month - 1) <= t then
        if k = 0 then
          if not exists (select 1 from public.acc_entries e where e.recurring_id = r.id and e.recurring_month = m and e.recurring_part > 0) then
            insert into public.acc_entries(kind,day,business,department,category,amount,method,party,note,recurring_id,recurring_month,recurring_part,created_by)
            values (r.kind, m + (r.day_of_month - 1), r.business, r.department, r.category, r.amount, r.method, r.party, coalesce(nullif(r.note,''),'Monthly'), r.id, m, 0, r.created_by)
            on conflict (recurring_id, recurring_month, recurring_part) where recurring_id is not null do nothing;
            if found then n := n + 1; end if;
          end if;
        elsif not exists (select 1 from public.acc_entries e where e.recurring_id = r.id and e.recurring_month = m and e.recurring_part = 0) then
          done_amt := 0; i := 0;
          for x in select * from jsonb_array_elements(r.split) loop
            i := i + 1;
            amt := case when i = k then r.amount - done_amt else round(r.amount * (x->>'pct')::numeric / 100, 2) end;
            done_amt := done_amt + amt;
            insert into public.acc_entries(kind,day,business,department,category,amount,method,party,note,recurring_id,recurring_month,recurring_part,created_by)
            values (r.kind, m + (r.day_of_month - 1), x->>'business', coalesce(x->>'department',''), r.category, amt, r.method, r.party,
              concat_ws(', ', nullif(r.note,''), (x->>'pct') || '% of ' || to_char(r.amount, 'FM999,999,990') || ' THB'), r.id, m, i, r.created_by)
            on conflict (recurring_id, recurring_month, recurring_part) where recurring_id is not null do nothing;
            if found then n := n + 1; end if;
          end loop;
        end if;
      end if;
      m := (m + interval '1 month')::date;
    end loop;
  end loop;
  return n;
end $function$;
