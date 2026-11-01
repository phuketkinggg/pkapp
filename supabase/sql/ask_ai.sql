-- Ask AI (feature: ask_ai): an assistant in the app for the owner and the staff the owner picks (Staff, Ask AI).
-- It reads with the person's own rights, and anything it changes (stock, products, emails) is shown first and only done
-- when the person taps Confirm. The ask-ai function does the talking to the AI.

-- who may use it: owners always, other staff only when the owner ticked Ask AI on them
create or replace function private.ai_allowed() returns boolean language sql stable security definer set search_path to '' as $$
  select private.feature('ask_ai', true) and exists (
    select 1 from public.staff s where s.user_id = auth.uid() and s.active
      and (s.role = 'manager' or coalesce(s.access->>'ai', '') = 'true'))
$$;
create or replace function public.ai_access() returns boolean language sql stable security definer set search_path to '' as $$ select private.ai_allowed() $$;
revoke all on function public.ai_access() from public, anon;
grant execute on function public.ai_access() to authenticated;

-- the tables and columns the assistant can ask about (names only, no data)
create or replace function public.ai_schema() returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  if not private.ai_allowed() then raise exception 'Ask AI is not turned on for you.'; end if;
  return (select jsonb_object_agg(t.table_name, t.cols) from (
    select c.table_name, string_agg(c.column_name || ':' || c.data_type, ', ' order by c.ordinal_position) cols
    from information_schema.columns c join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name
    where c.table_schema = 'public' and tb.table_type = 'BASE TABLE'
      and c.table_name not in ('push_subs','sync_settings','inbound_mails','web_push_keys')
    group by c.table_name) t);
end $f$;
revoke all on function public.ai_schema() from public, anon;
grant execute on function public.ai_schema() to authenticated;
notify pgrst, 'reload schema';
