-- Private health records (feature health_private), part 2: the functions that read or change health use private.health_can
-- (from health_private.sql) instead of the coaching rule. Each patch checks it applied and skips cleanly where a function is missing or older.
do $patch$
declare f text; d text; n text;
begin
  foreach f in array array['public.member_file_get(uuid)','public.member_file_save(uuid,jsonb)','public.member_consent_set(uuid,boolean)','public.member_note_save(jsonb)',
    'public.member_note_remove(uuid)','public.member_doc_add(jsonb)','public.member_doc_remove(uuid)','public.member_doc_share(uuid,boolean)','public.pangea_health_add(jsonb)','public.pangea_health_remove(uuid)'] loop
    if to_regprocedure(f) is null then raise notice 'health_private: % not here, skipped', f; continue; end if;
    d := pg_get_functiondef(to_regprocedure(f));
    if position('private.health_can(' in d) > 0 then continue; end if;
    n := replace(replace(d, 'private.coach_can(', 'private.health_can('), 'Only this member''''s coaches and the managers can open their file.', 'Health records are private. Ask the owner to let you see them.');
    if n = d then raise notice 'health_private: % is a different version, skipped', f; continue; end if;
    execute n;
    if position('private.health_can(' in pg_get_functiondef(to_regprocedure(f))) = 0 then raise exception 'health_private: % did not change', f; end if;
  end loop;

  -- files: a member's file and health uploads (path member/file/... and member/health/...) need health access
  if to_regprocedure('private.coach_path_ok(text)') is not null then
    d := pg_get_functiondef('private.coach_path_ok(text)'::regprocedure);
    if position('health_can' in d) = 0 then
      n := replace(d, 'or private.coach_can(v::uuid);', 'or (case when split_part(p_name, ''/'', 2) in (''file'', ''health'') then private.health_can(v::uuid) else private.coach_can(v::uuid) end);');
      if n = d then raise notice 'health_private: coach_path_ok is a different version, skipped';
      else execute n; if position('health_can' in pg_get_functiondef('private.coach_path_ok(text)'::regprocedure)) = 0 then raise exception 'health_private: coach_path_ok did not change'; end if; end if;
    end if;
  end if;

  -- the Pangea client page: coaching stays, health numbers and blood tests only for those allowed
  if to_regprocedure('public.pangea_client(uuid)') is not null then
    d := pg_get_functiondef('public.pangea_client(uuid)'::regprocedure);
    if position('health_can' in d) = 0 then
      n := replace(d, 'where h.customer_id = p_customer and not h.removed', 'where h.customer_id = p_customer and not h.removed and private.health_can(p_customer)');
      if n = d then raise notice 'health_private: pangea_client is a different version, skipped';
      else execute n; if position('health_can' in pg_get_functiondef('public.pangea_client(uuid)'::regprocedure)) = 0 then raise exception 'health_private: pangea_client did not change'; end if; end if;
    end if;
  end if;

  -- the About you form: injuries only for those allowed (allergies stay, the kitchen needs them)
  if to_regprocedure('public.customer_intake_get(uuid)') is not null then
    d := pg_get_functiondef('public.customer_intake_get(uuid)'::regprocedure);
    if position('health_can' in d) = 0 then
      n := replace(d, $r$'answers', coalesce(ci.answers, pa.answers, '{}'::jsonb),$r$,
        $r$'answers', case when private.health_can(p_customer) then coalesce(ci.answers, pa.answers, '{}'::jsonb) else coalesce(ci.answers, pa.answers, '{}'::jsonb) - 'injury' - 'injury_where' - 'injury_note' end, 'health_hidden', not private.health_can(p_customer),$r$);
      if n = d then raise notice 'health_private: customer_intake_get is a different version, skipped';
      else execute n; if position('health_can' in pg_get_functiondef('public.customer_intake_get(uuid)'::regprocedure)) = 0 then raise exception 'health_private: customer_intake_get did not change'; end if; end if;
    end if;
  end if;

  -- the notice when someone fills in the About you form: no injury in it while health is private
  if to_regprocedure('public.prearrival_save(jsonb,boolean)') is not null then
    d := pg_get_functiondef('public.prearrival_save(jsonb,boolean)'::regprocedure);
    if position('health_private' in d) = 0 then
      n := replace(d, $r$case when a->>'injury'='yes' then 'Injury: '$r$, $r$case when a->>'injury'='yes' and not private.feature('health_private', true) then 'Injury: '$r$);
      if n = d then raise notice 'health_private: prearrival_save is a different version, skipped';
      else execute n; end if;
    end if;
  end if;
  -- Coaching, Arriving soon: injuries only for those allowed
  if to_regprocedure('public.prearrival_list()') is not null then
    d := pg_get_functiondef('public.prearrival_list()'::regprocedure);
    if position('health_can' in d) = 0 then
      n := replace(replace(d, $r$'answers', p.answers,$r$, $r$'answers', case when private.health_can(c.id) then p.answers else p.answers - 'injury' - 'injury_where' - 'injury_note' end,$r$),
        $r$'answers', coalesce(ci.answers, '{}'::jsonb),$r$, $r$'answers', case when private.health_can(c.id) then coalesce(ci.answers, '{}'::jsonb) else coalesce(ci.answers, '{}'::jsonb) - 'injury' - 'injury_where' - 'injury_note' end,$r$);
      if n = d then raise notice 'health_private: prearrival_list is a different version, skipped';
      else execute n; if position('health_can' in pg_get_functiondef('public.prearrival_list()'::regprocedure)) = 0 then raise exception 'health_private: prearrival_list did not change'; end if; end if;
    end if;
  end if;

  -- the coaches' evening email goes to the whole team: no injuries in it while health is private
  if to_regprocedure('public.coach_brief(date)') is not null then
    d := pg_get_functiondef('public.coach_brief(date)'::regprocedure);
    if position('health_private' in d) = 0 then
      n := replace(d, $r$'answers', coalesce(nullif(p.answers, '{}'::jsonb), ci.answers, '{}'::jsonb),$r$,
        $r$'answers', coalesce(nullif(p.answers, '{}'::jsonb), ci.answers, '{}'::jsonb) - case when private.feature('health_private', true) then array['injury','injury_where','injury_note'] else array[]::text[] end,$r$);
      if n = d then raise notice 'health_private: coach_brief is a different version, skipped';
      else execute n; if position('health_private' in pg_get_functiondef('public.coach_brief(date)'::regprocedure)) = 0 then raise exception 'health_private: coach_brief did not change'; end if; end if;
    end if;
  end if;
end $patch$;
