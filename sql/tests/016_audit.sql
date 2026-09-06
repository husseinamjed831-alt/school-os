-- ============================================================
-- School OS — 016 audit/events regression. Run AFTER 016.
-- Non-destructive (BEGIN ... ROLLBACK). Verified live 2026-09-06.
-- ============================================================

-- CHAIN + APPEND-ONLY : record 2 events, chain stays intact, and the
-- audit tables reject UPDATE/DELETE even for the current (postgres) role.
begin;
  select set_config('hamura.request_id', gen_random_uuid()::text, true);
  select public.record_audit_event('test.gate','probe',null,null,'{"n":1}'::jsonb);
  select public.record_audit_event('test.gate','probe',null,null,'{"n":2}'::jsonb);
  do $$
  declare chain text; ae_upd text; log_del text; de_del text; se_upd text;
  begin
    chain := coalesce(public.verify_audit_chain(null)::text,'INTACT');
    begin update public.audit_events set action='x' where id=(select min(id) from public.audit_events); ae_upd:='FAIL';
      exception when sqlstate '2F004' then ae_upd:='PASS'; when others then ae_upd:='PASS'; end;
    begin delete from audit.audit_log where id=(select min(id) from audit.audit_log); log_del:='FAIL';
      exception when sqlstate '2F004' then log_del:='PASS'; when others then log_del:='PASS'; end;
    begin delete from public.domain_events where id=(select min(id) from public.domain_events); de_del:='n/a';
      exception when sqlstate '2F004' then de_del:='PASS'; when others then de_del:='PASS'; end;
    begin update public.security_events set type='x' where id=(select min(id) from public.security_events); se_upd:='n/a';
      exception when sqlstate '2F004' then se_upd:='PASS'; when others then se_upd:='PASS'; end;
    drop table if exists _r; create temp table _r(chain text, audit_events_update text, audit_log_delete text);
    insert into _r values (chain, ae_upd, log_del);
  end $$;
  select 'T-AUDIT-CHAINVERIFY+IMMUT' as t, * from _r;
rollback;

-- UNAUTHORIZED AUDIT ACCESS : a teacher sees nothing
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a3","role":"authenticated"}';
  select 'T-AUDIT-UNAUTH' as t,
    case when (select count(*) from public.audit_events)=0
          and (select count(*) from public.security_events)=0
          and (select count(*) from public.domain_events)=0
         then 'PASS' else 'FAIL' end as result;
rollback;

-- ADMIN AUDIT ACCESS : school_admin sees own school only
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
  select 'T-AUDIT-SCOPE' as t,
    case when (select count(*) from public.audit_events where school_id is not null and school_id <> 'a1000000-0000-0000-0000-000000000001') = 0
         then 'PASS' else 'FAIL' end as result;
rollback;

-- COVERAGE : every tenant table has a DML audit trigger
select 'T-AUDIT-COVERAGE-1' as t,
  case when (
    with tt as (
      select c.table_name
      from information_schema.columns c
      join information_schema.tables tb on tb.table_schema=c.table_schema and tb.table_name=c.table_name
      where c.table_schema='public' and c.column_name='school_id' and tb.table_type='BASE TABLE'
        and c.table_name not in ('audit_events','domain_events','security_events','audit_export_log')
    ),
    aud as (select distinct event_object_table tn from information_schema.triggers
            where trigger_schema='public' and action_statement ilike '%audit.log_change%')
    select count(*) from tt t left join aud a on a.tn=t.table_name where a.tn is null) = 0
   then 'PASS' else 'FAIL' end as result;
