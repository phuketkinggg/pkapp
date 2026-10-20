-- Classes: an optional end time, shown with the start time in the timetable, the member app and the website.
alter table public.classes add column if not exists end_time time;
do $$
declare f text; d text;
begin
  foreach f in array array['public.customer_home()','public.customer_home_as(uuid)'] loop
    begin d := pg_get_functiondef(f::regprocedure); exception when others then continue; end;
    if position('''end'', to_char(k.end_time' in d) = 0 then
      d := replace(d, '''time'', to_char(k.start_time, ''HH24:MI''),', '''time'', to_char(k.start_time, ''HH24:MI''), ''end'', to_char(k.end_time, ''HH24:MI''),');
      execute d;
    end if;
  end loop;
end $$;
