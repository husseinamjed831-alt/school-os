-- ============================================================
-- School OS — 015 ROLLBACK. students.section_id + its data are UNTOUCHED,
-- so dropping the new structures returns the system to its exact pre-015
-- behaviour. (This is why section_id is not dropped in 015.)
-- ============================================================
begin;

drop trigger if exists students_section_mirror on public.students;
drop trigger if exists section_assignment_mirror on public.section_assignments;
drop function if exists public.trg_students_section_mirror();
drop function if exists public.trg_section_assignment_mirror();

drop function if exists public.correct_enrollment_placement(uuid,uuid,uuid,uuid,text);
drop function if exists public.withdraw_student(uuid,text);
drop function if exists public.assign_section(uuid,uuid,text);
drop function if exists public.activate_enrollment(uuid);
drop function if exists public.create_enrollment(uuid,uuid,uuid,uuid,uuid);

drop view if exists public.enrollment_snapshot;

drop table if exists public.enrollment_versions;
drop table if exists public.section_assignments;
drop table if exists public.enrollments;   -- freeze trigger + audit + enforce triggers go with it

drop table if exists public.school_settings;
drop table if exists public.academic_terms;
drop table if exists public.grade_levels;

drop function if exists public.trg_enrollment_freeze();

-- NOTE: the placeholder academic_years rows created in step 0 are left in
-- place (harmless; a school with active students genuinely needs one).
-- To remove them:  delete from academic_years where label like 'ترحيل %';

commit;
