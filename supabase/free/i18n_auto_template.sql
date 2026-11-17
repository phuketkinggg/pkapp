delete from mf.template where name like 'i18n_auto:%';
insert into mf.template (ord, phase, kind, name, sql) values (303541, 3, 'patch', 'i18n_auto:303541', $TPL$create table if not exists __P__.i18n_auto (
  lang text not null,
  en text not null,
  tr text not null,
  at timestamptz not null default now(),
  primary key (lang, en)
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303542, 3, 'patch', 'i18n_auto:303542', $TPL$alter table __P__.i18n_auto enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197701, 11, 'patch', 'i18n_auto:1197701', $TPL$revoke all on __P__.i18n_auto from public, anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403701, 4, 'patch', 'i18n_auto:403701', $TPL$create or replace function __P__.i18n_pack(p_lang text) returns jsonb language sql stable security definer set search_path to '' as $f$
  select case when p_lang ~ '^[a-z]{2}$' and __Q__.feature('lang_' || p_lang, false) then jsonb_build_object(
    'd', coalesce((select jsonb_object_agg(btrim(en), tr) from __P__.i18n_auto where lang = p_lang and btrim(tr) <> '' and btrim(en) <> ''), '{}'::jsonb),
    'p', coalesce((select jsonb_object_agg(btrim(en), 1) from __P__.i18n_auto where lang = p_lang and btrim(tr) <> '' and btrim(en) <> ''
                   and (en <> btrim(en) or btrim(en) ~ '^[,.:;(]' or btrim(en) ~ '[,:(]$')), '{}'::jsonb))
  else '{}'::jsonb end
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197702, 11, 'patch', 'i18n_auto:1197702', $TPL$revoke all on function __P__.i18n_pack(text) from public;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197703, 11, 'patch', 'i18n_auto:1197703', $TPL$grant execute on function __P__.i18n_pack(text) to anon, authenticated;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (403702, 4, 'patch', 'i18n_auto:403702', $TPL$create or replace function __P__.i18n_count(p_lang text) returns integer language sql stable security definer set search_path to '' as $f$
  select count(*)::int from __P__.i18n_auto where lang = p_lang
$f$;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197704, 11, 'patch', 'i18n_auto:1197704', $TPL$revoke all on function __P__.i18n_count(text) from public, anon;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197705, 11, 'patch', 'i18n_auto:1197705', $TPL$grant execute on function __P__.i18n_count(text) to authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'i18n_auto:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
