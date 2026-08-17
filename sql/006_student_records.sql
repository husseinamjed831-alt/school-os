-- ============================================================
-- School OS — 006: behavior records + teacher notes (Student 360 inputs)
-- Depends on: 001 (schools/students/subjects/profiles), 002 (my_role(),
--   my_school_id()), 003 (audit.log_change()), 004 (fn_teaches_student())
-- ============================================================

create table behavior_records (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  category text not null check (category in ('positive','concern')),
  note text not null,
  recorded_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index behavior_records_school_idx on behavior_records(school_id);
create index behavior_records_student_idx on behavior_records(student_id);

create table teacher_notes (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  subject_id uuid references subjects(id) on delete set null,
  note text not null,
  is_visible_to_parent boolean not null default false,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index teacher_notes_school_idx on teacher_notes(school_id);
create index teacher_notes_student_idx on teacher_notes(student_id);

alter table behavior_records enable row level security;
alter table teacher_notes enable row level security;

-- ---------- behavior_records ----------
-- Visible to school staff and parents (transparency), not exposed to the
-- student's own account directly in this phase — no RLS policy grants
-- student-role select, which is a deliberate default-deny.
create policy super_admin_all_behavior on behavior_records for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_behavior on behavior_records for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_behavior on behavior_records for all
  using (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  )
  with check (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  );
create policy teacher_manage_own_behavior on behavior_records for all
  using (my_role() = 'teacher' and fn_teaches_student(student_id))
  with check (my_role() = 'teacher' and fn_teaches_student(student_id));
create policy parent_read_children_behavior on behavior_records for select
  using (student_id in (select id from students where parent_id = auth.uid()));

-- ---------- teacher_notes ----------
create policy super_admin_all_notes on teacher_notes for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_notes on teacher_notes for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_notes on teacher_notes for all
  using (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  )
  with check (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  );
create policy teacher_manage_own_notes on teacher_notes for all
  using (my_role() = 'teacher' and fn_teaches_student(student_id))
  with check (my_role() = 'teacher' and fn_teaches_student(student_id));
-- Parents/students only ever see notes a teacher explicitly marked shared.
create policy parent_read_visible_notes on teacher_notes for select
  using (is_visible_to_parent = true and student_id in (select id from students where parent_id = auth.uid()));
create policy student_read_visible_notes on teacher_notes for select
  using (is_visible_to_parent = true and student_id in (select id from students where profile_id = auth.uid()));

create trigger audit_behavior_records after insert or update or delete on behavior_records
  for each row execute function audit.log_change();
create trigger audit_teacher_notes after insert or update or delete on teacher_notes
  for each row execute function audit.log_change();
