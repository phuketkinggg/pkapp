-- One-time notices remembered for the person, not the device: once someone hides the setup guide or has seen what is new,
-- it stays hidden on every phone, tablet and computer they sign in on, and after the app is reinstalled.

create table if not exists public.user_flags (
  user_id uuid not null,
  key text not null check (key ~ '^[a-z_]{2,30}$'),
  value text,
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table public.user_flags enable row level security;
revoke all on public.user_flags from public, anon, authenticated;

create or replace function public.my_flags() returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from public.user_flags where user_id = auth.uid()
$f$;

create or replace function public.my_flag_set(p_key text, p_value text) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_key !~ '^[a-z_]{2,30}$' then raise exception 'Unknown setting.'; end if;
  insert into public.user_flags (user_id, key, value) values (auth.uid(), p_key, left(p_value, 200))
    on conflict (user_id, key) do update set value = excluded.value, updated_at = now();
end $f$;

revoke all on function public.my_flags() from public, anon;
revoke all on function public.my_flag_set(text, text) from public, anon;
grant execute on function public.my_flags() to authenticated;
grant execute on function public.my_flag_set(text, text) to authenticated;

notify pgrst, 'reload schema';
