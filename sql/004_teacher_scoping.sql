-- ============================================================
-- School OS — 004: teacher scoping + attendance hardening
-- Depends on: 001 (teachers/attendance/students/subjects/sections tables),
--   002 (my_role(), my_school_id() — and the teacher_write_attendance
--   policy this file drops and replaces), 003 (audit.log_change() used by
--   the new staff_attendance trigger)
-- Does not modify 001/002/003 — only adds new objects and new policies
-- (drops+recreates only the one teacher policy that was too broad;
-- everything else from 002 stands).
-- ============================================================

-- teachers.branch_id was NOT NULL, but a teacher created by a school_admin
-- (not a branch_admin) may not have a branch yet. Relax it, same reasoning
-- as students.branch_id in Phase 3.5.
alter table teachers alter column branch_id drop not null;

-- Backfill: every profile with role='teacher' must have a matching teachers
-- row, or the section-scoping functions below can't resolve them. This is
-- idempotent — safe to re-run.
insert into teachers (school_id, branch_id, profile_id)
select p.school_id, p.branch_id, p.id
from profiles p
where p.role = 'teacher'
  and not exists (select 1 from teachers t where t.profile_id = p.id);

-- ---------- Attendance: missing pieces from Phase 3.5 ----------
alter table attendance add column if not exists note text;

-- branch_admin had NO policy at all on attendance (a real gap from Phase
-- 3.5) — add it, scoped to students in their own branch.
create policy branch_admin_all_attendance on attendance for all
  using (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  )
  with check (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  );

-- ---------- Teacher scoping helpers ----------
-- A teacher "teaches" a section if they are assigned (via subjects.teacher_id)
-- to at least one subject in that section's class.
create or replace function fn_teaches_section(p_section_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from sections sec
    join subjects sub on sub.class_id = sec.class_id
    join teachers t on t.id = sub.teacher_id
    where sec.id = p_section_id and t.profile_id = auth.uid()
  )
$$;

create or replace function fn_teaches_student(p_student_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from students st
    join sections sec on sec.id = st.section_id
    join subjects sub on sub.class_id = sec.class_id
    join teachers t on t.id = sub.teacher_id
    where st.id = p_student_id and t.profile_id = auth.uid()
  )
$$;

-- ---------- Replace the Phase 3.5 teacher attendance policy ----------
-- The old policy let ANY teacher write attendance for ANY student in the
-- school — too broad. Replace with section-scoped read/write.
drop policy if exists teacher_write_attendance on attendance;

create policy teacher_read_attendance on attendance for select
  using (my_role() = 'teacher' and fn_teaches_student(student_id));

create policy teacher_write_attendance on attendance for insert
  with check (my_role() = 'teacher' and fn_teaches_student(student_id));

create policy teacher_update_attendance on attendance for update
  using (my_role() = 'teacher' and fn_teaches_student(student_id))
  with check (my_role() = 'teacher' and fn_teaches_student(student_id));

-- ---------- Staff (teacher) attendance ----------
create table staff_attendance (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  date date not null default current_date,
  status text not null check (status in ('present','absent','late','excused')),
  note text,
  recorded_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (profile_id, date)
);
create index staff_attendance_school_idx on staff_attendance(school_id);
alter table staff_attendance enable row level security;

create policy super_admin_all_staff_attendance on staff_attendance for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_staff_attendance on staff_attendance for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_staff_attendance on staff_attendance for all
  using (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and profile_id in (select id from profiles where branch_id = my_branch_id())
  )
  with check (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and profile_id in (select id from profiles where branch_id = my_branch_id())
  );
create policy own_staff_attendance on staff_attendance for select
  using (profile_id = auth.uid());

create trigger audit_staff_attendance after insert or update or delete on staff_attendance
  for each row execute function audit.log_change();
