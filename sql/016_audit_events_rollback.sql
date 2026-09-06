-- ============================================================
-- School OS — 016 ROLLBACK. Drops the new event tables + functions and
-- restores audit.log_change() to its 003 body. audit.audit_log DATA is
-- kept; the 3 added columns are dropped; the immutability trigger removed.
-- The DML triggers added to the 9 previously-unaudited tables are dropped.
-- ============================================================
begin;

-- drop the audit triggers 016 added to the 9 tables
do $$
declare r record;
begin
  for r in select event_object_table tn, trigger_name
           from information_schema.triggers
           where trigger_schema='public'
             and trigger_name in ('audit_branches','audit_fees','audit_subjects','audit_teachers',
               'audit_notifications','audit_schedule','audit_academic_years',
               'audit_assessment_types','audit_grading_scales')
  loop execute format('drop trigger if exists %I on public.%I', r.trigger_name, r.tn); end loop;
end $$;

drop function if exists public.read_audit_events(text,text,timestamptz,int);
drop function if exists public.record_security_event(text,text,jsonb,uuid,uuid);
drop function if exists public.dispatch_domain_events(int);
drop function if exists public.emit_event(text,text,uuid,jsonb);
drop function if exists public.verify_audit_chain(uuid);
drop function if exists public.record_audit_event(text,text,uuid,jsonb,jsonb);

drop table if exists public.audit_export_log;
drop table if exists public.security_events;
drop table if exists public.domain_events;
drop function if exists public.domain_events_guard();
drop table if exists public.audit_events;
drop function if exists public.audit_events_chain();

drop trigger if exists audit_log_immutable on audit.audit_log;
drop function if exists audit.deny_mutation();

alter table audit.audit_log drop column if exists request_id;
alter table audit.audit_log drop column if exists actor_role;
alter table audit.audit_log drop column if exists impersonated_by;

-- restore 003 audit.log_change()
create or replace function audit.log_change() returns trigger
language plpgsql security definer set search_path = public, audit as $$
declare v_school_id uuid; v_row_id text;
begin
  v_school_id := coalesce(case when TG_OP='DELETE' then (to_jsonb(old)->>'school_id')::uuid
                               else (to_jsonb(new)->>'school_id')::uuid end, null);
  v_row_id := case when TG_OP='DELETE' then (to_jsonb(old)->>'id') else (to_jsonb(new)->>'id') end;
  insert into audit.audit_log (school_id, table_name, row_id, action, actor, old_data, new_data)
  values (v_school_id, TG_TABLE_NAME, v_row_id, TG_OP, auth.uid(),
    case when TG_OP in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when TG_OP in ('UPDATE','INSERT') then to_jsonb(new) else null end);
  return coalesce(new, old);
end; $$;

grant insert on audit.audit_log to authenticated;  -- restore Supabase default-ish

commit;
