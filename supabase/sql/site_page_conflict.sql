-- Website pages: an editor that was open for a long time can no longer save an older copy over newer changes
-- (made in another place, or by someone else). The app sends base: the time the copy it edits was saved.
-- Patch: checks it applied, skips cleanly where site_page_save is a different version.
do $patch$
declare s text; n text;
begin
  if to_regprocedure('public.site_page_save(jsonb)') is null then raise notice 'site_page_conflict: no site_page_save here, skipped'; return; end if;
  s := pg_get_functiondef('public.site_page_save(jsonb)'::regprocedure);
  if s like '%changed in another place%' then return; end if;
  n := replace(s, $a$  else
    update public.site_pages set slug=s,$a$, $a$  else
    if nullif(p->>'base','') is not null and exists (select 1 from public.site_pages x where x.id = v_id and x.updated_at > (p->>'base')::timestamptz + interval '2 seconds') then
      raise exception 'This page was changed in another place since you opened it. Close it and open it again to get the latest copy, then make your change.';
    end if;
    update public.site_pages set slug=s,$a$);
  n := replace(n, $a$return jsonb_build_object('id',r.id,'slug',r.slug,'preview_token',r.preview_token,'status',r.status);$a$,
                  $a$return jsonb_build_object('id',r.id,'slug',r.slug,'preview_token',r.preview_token,'status',r.status,'updated_at',r.updated_at);$a$);
  if n not like '%changed in another place%' or n not like '%''updated_at'',r.updated_at%' then raise notice 'site_page_conflict: site_page_save is a different version here, skipped'; return; end if;
  execute n;
end $patch$;
notify pgrst, 'reload schema';
