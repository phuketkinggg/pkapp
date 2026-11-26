delete from mf.template where name like 'arrival_email:%';
insert into mf.template (ord, phase, kind, name, sql) values (305701, 3, 'patch', 'arrival_email:305701', $TPL$alter table __P__.stays add column if not exists arrival_sent_at timestamptz;$TPL$);
insert into mf.template (ord, phase, kind, name, sql) values (1004301, 10, 'patch', 'arrival_email:1004301', $TPL$do $p$ begin
  if to_regclass('__P__.stay_emails') is not null then
    alter table __P__.stay_emails add column if not exists kind text not null default 'welcome';
  end if;
end $p$;$TPL$);
do $$ declare g record; r record; begin
  for g in select * from mf.gyms where status = 'ready' loop
    for r in select sql from mf.template where name like 'arrival_email:%' order by ord loop
      execute replace(replace(r.sql, '__P__', g.schema_pub), '__Q__', g.schema_priv);
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
