-- WhatsApp connected with the Meta sign in: the access token lasts 60 days. wa_status says whether the number was connected
-- with the sign in (signin), so the app can ask a manager to reconnect before it runs out. Patched, checking it applied.
do $p$
declare d text; n text;
begin
  if to_regprocedure('public.wa_status()') is null then raise notice 'no wa_status here, skipped'; return; end if;
  d := pg_get_functiondef('public.wa_status()'::regprocedure);
  if position('''signin''' in d) > 0 then raise notice 'wa_status already patched'; return; end if;
  n := replace(d, $x$'coexist', coexist, 'at', connected_at)$x$, $x$'coexist', coexist, 'at', connected_at, 'signin', token is not null)$x$);
  if n = d then raise notice 'wa_status: older version, skipped'; return; end if;
  execute n;
  if position('''signin''' in pg_get_functiondef('public.wa_status()'::regprocedure)) = 0 then raise exception 'wa_status patch did not apply'; end if;
end $p$;
notify pgrst, 'reload schema';
