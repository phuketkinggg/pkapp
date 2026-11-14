-- Phone notifications in the store apps (iPhone and Android): the phone is saved with its code as "apns:<code>" or "fcm:<code>",
-- next to web push addresses (https://...). Every schema with a push_subs table is updated (the free gyms have one per gym).
do $p$
declare r record;
begin
  for r in select n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relname = 'push_subs' and c.relkind = 'r' loop
    execute format('alter table %I.push_subs drop constraint if exists push_subs_endpoint_check', r.nspname);
    execute format('alter table %I.push_subs add constraint push_subs_endpoint_check check (endpoint ~ ''^(https://|apns:|fcm:)'' and char_length(endpoint) <= 800)', r.nspname);
  end loop;
end $p$;
