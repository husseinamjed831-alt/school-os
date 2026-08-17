-- ============================================================
-- School OS — 002: RLS helper functions + tenant isolation policies
-- Depends on: 001 (every table this adds policies to)
-- ============================================================

-- ---------- Helper functions (security definer: safe to call from RLS) ----------
create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function my_school_id() returns uuid
language sql stable security definer set search_path = public as $$
  select school_id from profiles where id = auth.uid()
$$;

create or replace function my_branch_id() returns uuid
language sql stable security definer set search_path = public as $$
  select branch_id from profiles where id = auth.uid()
$$;

create or replace function is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from profiles where id = auth.uid()) = 'super_admin', false)
$$;

-- ---------- Enable RLS everywhere ----------
alter table schools enable row level security;
alter table branches enable row level security;
alter table academic_years enable row level security;
alter table profiles enable row level security;
alter table classes enable row level security;
alter table sections enable row level security;
alter table teachers enable row level security;
alter table students enable row level security;
alter table subjects enable row level security;
alter table schedule enable row level security;
alter table attendance enable row level security;
alter table grades enable row level security;
alter table notifications enable row level security;

-- ---------- schools ----------
-- super_admin: full access to every tenant.
create policy super_admin_all_schools on schools for all
  using (is_super_admin()) with check (is_super_admin());
-- everyone else can only read their own school row.
create policy read_own_school on schools for select
  using (id = my_school_id());

-- ---------- branches ----------
create policy super_admin_all_branches on branches for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_branches on branches for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy read_own_branches on branches for select
  using (school_id = my_school_id());

-- ---------- academic_years ----------
create policy super_admin_all_years on academic_years for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_years on academic_years for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy read_own_years on academic_years for select
  using (school_id = my_school_id());

-- ---------- profiles ----------
-- Row inserts happen only through the create-user Edge Function (service_role
-- bypasses RLS) so there is deliberately no INSERT policy for authenticated
-- users here — direct client inserts into profiles are always denied.
create policy super_admin_all_profiles on profiles for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_manage_profiles on profiles for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
-- branch_admin needs at least read+deactivate on the accounts inside their
-- own branch (teachers, parents/students created by them) to run the users
-- list and dashboard counts. It cannot re-parent a profile to another branch.
create policy branch_admin_read_profiles on profiles for select
  using (my_role() = 'branch_admin' and branch_id = my_branch_id());
create policy branch_admin_update_profiles on profiles for update
  using (my_role() = 'branch_admin' and branch_id = my_branch_id())
  with check (my_role() = 'branch_admin' and branch_id = my_branch_id());
create policy read_own_profile on profiles for select
  using (id = auth.uid());
create policy update_own_profile on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- ---------- classes ----------
create policy super_admin_all_classes on classes for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_classes on classes for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_classes on classes for all
  using (my_role() = 'branch_admin' and branch_id = my_branch_id())
  with check (my_role() = 'branch_admin' and branch_id = my_branch_id());
create policy read_own_school_classes on classes for select
  using (school_id = my_school_id());

-- ---------- sections ----------
create policy super_admin_all_sections on sections for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_sections on sections for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_sections on sections for all
  using (my_role() = 'branch_admin' and school_id = my_school_id()
    and class_id in (select id from classes where branch_id = my_branch_id()))
  with check (my_role() = 'branch_admin' and school_id = my_school_id()
    and class_id in (select id from classes where branch_id = my_branch_id()));
create policy read_own_school_sections on sections for select
  using (school_id = my_school_id());

-- ---------- teachers ----------
create policy super_admin_all_teachers on teachers for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_teachers on teachers for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_teachers on teachers for all
  using (my_role() = 'branch_admin' and branch_id = my_branch_id())
  with check (my_role() = 'branch_admin' and branch_id = my_branch_id());
create policy read_own_school_teachers on teachers for select
  using (school_id = my_school_id());

-- ---------- students ----------
create policy super_admin_all_students on students for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_students on students for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_students on students for all
  using (my_role() = 'branch_admin' and branch_id = my_branch_id())
  with check (my_role() = 'branch_admin' and branch_id = my_branch_id());
create policy teacher_read_students on students for select
  using (my_role() = 'teacher' and school_id = my_school_id());
create policy student_own_row on students for select
  using (profile_id = auth.uid());
create policy parent_children on students for select
  using (parent_id = auth.uid());

-- ---------- subjects ----------
create policy super_admin_all_subjects on subjects for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_subjects on subjects for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_subjects on subjects for all
  using (my_role() = 'branch_admin' and school_id = my_school_id()
    and class_id in (select id from classes where branch_id = my_branch_id()))
  with check (my_role() = 'branch_admin' and school_id = my_school_id()
    and class_id in (select id from classes where branch_id = my_branch_id()));
create policy read_own_school_subjects on subjects for select
  using (school_id = my_school_id());

-- ---------- schedule ----------
create policy super_admin_all_schedule on schedule for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_schedule on schedule for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_schedule on schedule for all
  using (my_role() = 'branch_admin' and school_id = my_school_id()
    and section_id in (select s.id from sections s join classes c on c.id = s.class_id where c.branch_id = my_branch_id()))
  with check (my_role() = 'branch_admin' and school_id = my_school_id()
    and section_id in (select s.id from sections s join classes c on c.id = s.class_id where c.branch_id = my_branch_id()));
create policy read_own_school_schedule on schedule for select
  using (school_id = my_school_id());

-- ---------- attendance ----------
create policy super_admin_all_attendance on attendance for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_attendance on attendance for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy teacher_write_attendance on attendance for all
  using (my_role() = 'teacher' and school_id = my_school_id())
  with check (my_role() = 'teacher' and school_id = my_school_id());
create policy student_own_attendance on attendance for select
  using (student_id in (select id from students where profile_id = auth.uid()));
create policy parent_children_attendance on attendance for select
  using (student_id in (select id from students where parent_id = auth.uid()));

-- ---------- grades ----------
create policy super_admin_all_grades on grades for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_grades on grades for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy teacher_write_grades on grades for all
  using (my_role() = 'teacher' and school_id = my_school_id())
  with check (my_role() = 'teacher' and school_id = my_school_id());
create policy student_own_grades on grades for select
  using (student_id in (select id from students where profile_id = auth.uid()));
create policy parent_children_grades on grades for select
  using (student_id in (select id from students where parent_id = auth.uid()));

-- ---------- notifications ----------
create policy super_admin_all_notifications on notifications for all
  using (is_super_admin()) with check (is_super_admin());
create policy own_notifications on notifications for select
  using (user_id = auth.uid());
create policy update_own_notifications on notifications for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy school_admin_insert_notifications on notifications for insert
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy teacher_insert_notifications on notifications for insert
  with check (my_role() = 'teacher' and school_id = my_school_id());
