-- 15 Nov 2026: free gyms were missing the column grant on staff.support, so the back office stopped with
-- "permission denied for table staff". Grant it on every gym made so far (new gyms get it from the template).
do $$ declare s text; begin
  for s in select schema_pub from mf.gyms where status = 'ready' loop
    execute format('grant select (support), insert (support), update (support) on %I.staff to authenticated', s);
  end loop;
end $$;
