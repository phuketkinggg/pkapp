-- Tidy and lock down (Nov 2026): app-only functions can no longer be called by people who are not signed in
-- (each one already checks the role inside; this closes the door one step earlier), and indexes for looking up a customer's records.
do $$ declare f text;
begin
  foreach f in array array['public.acc_checks_list(date,date)','public.acc_feed_link(boolean)','public.add_pay_extras(text,uuid,integer,integer)','public.affiliate_mine()',
    'public.affiliate_pay(uuid,integer,text,text,date)','public.affiliate_payout_undo(uuid)','public.affiliate_save(jsonb)','public.affiliates_list()',
    'public.invoice_cancel(uuid)','public.invoice_paid(uuid,text,date,text,boolean)','public.invoice_save(jsonb)','public.invoice_unpaid(uuid)','public.invoices_list()',
    'public.shop_order_extras(uuid,integer,integer)','public.mf_schema_export(text)'] loop
    if to_regprocedure(f) is null then continue; end if;
    execute format('revoke all on function %s from public, anon', f);
    if f <> 'public.mf_schema_export(text)' then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;

do $$ declare t text; c text;
begin
  foreach t in array array['group_members','web_pkg_orders','invoices','agency_bookings','health_access','fighter_applications','newsletter_sends'] loop
    c := 'customer_id';
    if to_regclass('public.' || t) is not null and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = c) then
      execute format('create index if not exists %I on public.%I (%I)', t || '_customer_ix', t, c);
    end if;
  end loop;
end $$;
