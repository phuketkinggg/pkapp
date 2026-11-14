-- GetYourGuide connection: every request and the answer's error (if any) is kept for 30 days, to fix problems in the tests.
create table if not exists public.gyg_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  op text, query jsonb, data jsonb, error text, message text
);
alter table public.gyg_log enable row level security;
revoke all on public.gyg_log from public, anon, authenticated;

do $p$
begin
  if to_regprocedure('private.gyg_handle(jsonb)') is null and to_regprocedure('public.gyg_api(jsonb)') is not null then
    alter function public.gyg_api(jsonb) rename to gyg_handle;
    alter function public.gyg_handle(jsonb) set schema private;
  end if;
end $p$;

create or replace function public.gyg_api(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $f$
declare r jsonb;
begin
  r := private.gyg_handle(p);
  insert into public.gyg_log (op, query, data, error, message)
    values (p->>'op', p->'query', (p->'data') - 'travelers', r->>'errorCode', left(coalesce(r->>'errorMessage', ''), 300));
  delete from public.gyg_log where at < now() - interval '30 days';
  return r;
end $f$;
revoke all on function public.gyg_api(jsonb) from public, anon, authenticated;
revoke all on function private.gyg_handle(jsonb) from public, anon, authenticated;
