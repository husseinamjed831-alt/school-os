-- ============================================================
-- School OS — 003: generic audit log
-- Depends on: 001 (students/profiles/grades/attendance/classes/sections
--   tables the triggers attach to), 002 (my_role(), is_super_admin() used
--   by the audit_log read policies)
-- ============================================================

create schema if not exists audit;

create table audit.audit_log (
  id bigint generated always as identity primary key,
  school_id uuid,
  table_name text not null,
  row_id text not null,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  actor uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);
create index audit_log_school_idx on audit.audit_log(school_id);
create index audit_log_table_row_idx on audit.audit_log(table_name, row_id);

-- audit.audit_log is never exposed to clients directly.
alter table audit.audit_log enable row level security;
create policy super_admin_read_audit on audit.audit_log for select
  using (is_super_admin());
create policy school_admin_read_own_audit on audit.audit_log for select
  using (my_role() = 'school_admin' and school_id = my_school_id());

create or replace function audit.log_change() returns trigger
language plpgsql security definer set search_path = public, audit as $$
declare
  v_school_id uuid;
  v_row_id text;
begin
  v_school_id := coalesce(
    case when TG_OP = 'DELETE' then (to_jsonb(old)->>'school_id')::uuid
         else (to_jsonb(new)->>'school_id')::uuid end,
    null
  );
  v_row_id := case when TG_OP = 'DELETE' then (to_jsonb(old)->>'id')
                    else (to_jsonb(new)->>'id') end;

  insert into audit.audit_log (school_id, table_name, row_id, action, actor, old_data, new_data)
  values (
    v_school_id,
    TG_TABLE_NAME,
    v_row_id,
    TG_OP,
    auth.uid(),
    case when TG_OP in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when TG_OP in ('UPDATE','INSERT') then to_jsonb(new) else null end
  );

  return coalesce(new, old);
end;
$$;

-- Attach to every sensitive table.
create trigger audit_students after insert or update or delete on students
  for each row execute function audit.log_change();
create trigger audit_profiles after insert or update or delete on profiles
  for each row execute function audit.log_change();
create trigger audit_grades after insert or update or delete on grades
  for each row execute function audit.log_change();
create trigger audit_attendance after insert or update or delete on attendance
  for each row execute function audit.log_change();
create trigger audit_classes after insert or update or delete on classes
  for each row execute function audit.log_change();
create trigger audit_sections after insert or update or delete on sections
  for each row execute function audit.log_change();
