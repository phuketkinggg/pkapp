-- Health consent with clear terms (member file): the member ticks that their health details, notes and files are kept privately,
-- only to look after them professionally, that the data stays theirs (we do not own it), and that it is never sold, shared for
-- marketing or used to make money. The record says which terms they agreed to. Patches check they applied and skip cleanly.
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.my_consent(boolean)') is null then raise notice 'no member file here, skipped'; return; end if;
  d := pg_get_functiondef('public.my_consent(boolean)'::regprocedure);
  if position('stays theirs' in d) > 0 then raise notice 'my_consent already patched'; return; end if;
  n := replace(d, $x$'In the app'$x$, $x$'In the app (terms 2: private, professional use only, the data stays theirs, never sold or used for profit)'$x$);
  if n = d then raise notice 'my_consent: older version, skipped'; return; end if;
  execute n;
end $p$;
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.member_consent_set(uuid,boolean)') is null then return; end if;
  d := pg_get_functiondef('public.member_consent_set(uuid,boolean)'::regprocedure);
  if position('stays theirs' in d) > 0 then raise notice 'member_consent_set already patched'; return; end if;
  n := replace(d, $x$then 'In person, recorded by ' || nm end)$x$, $x$then 'In person (terms 2: private, professional use only, the data stays theirs, never sold or used for profit), recorded by ' || nm end)$x$);
  n := replace(n, $x$consent_how = case when p_on then 'In person, recorded by ' || nm else$x$, $x$consent_how = case when p_on then 'In person (terms 2: private, professional use only, the data stays theirs, never sold or used for profit), recorded by ' || nm else$x$);
  if n = d then raise notice 'member_consent_set: older version, skipped'; return; end if;
  execute n;
end $p$;
notify pgrst, 'reload schema';
