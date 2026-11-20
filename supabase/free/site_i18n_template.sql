delete from mf.template where name like 'site_i18n:%';
insert into mf.template (ord, phase, kind, name, sql) values (303701, 3, 'patch', 'site_i18n:303701', $TPL$create table if not exists __P__.site_i18n (
  lang text not null,
  en text not null,
  tr text not null,
  at timestamptz not null default now(),
  primary key (lang, en)
);$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (303702, 3, 'patch', 'site_i18n:303702', $TPL$alter table __P__.site_i18n enable row level security;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1197901, 11, 'patch', 'site_i18n:1197901', $TPL$revoke all on __P__.site_i18n from public, anon, authenticated;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'site_i18n:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
