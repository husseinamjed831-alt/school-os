-- ============================================================
-- School OS — 011: V1 release hardening
-- Depends on: 001 (schools), 002 (my_role/my_school_id), 004
--   (fn_teaches_student), 005 (assessments/assessment_scores)
--
-- Two independent, additive fixes found during the V1 production audit.
-- Neither touches existing data beyond a safe column default backfill.
-- ============================================================

-- ---------- Fix 1: teacher RLS on assessments/assessment_scores was ----------
-- missing a school_id check (every other tier's policy — school_admin,
-- branch_admin — includes it; the teacher policy didn't). fn_teaches_student
-- /the subjects.teacher_id join already ties the row to a subject the
-- teacher legitimately teaches, so this could not be exploited through the
-- app UI — but a teacher calling the REST API directly with a crafted
-- school_id in the request body could have inserted a row whose school_id
-- didn't match their own tenant, corrupting any report keyed by school_id.
-- Defense in depth: require school_id = my_school_id() too, same as every
-- other role's policy on these tables.
drop policy if exists teacher_manage_own_assessments on assessments;
create policy teacher_manage_own_assessments on assessments for all
  using (
    my_role() = 'teacher' and school_id = my_school_id()
    and subject_id in (select s.id from subjects s join teachers t on t.id = s.teacher_id where t.profile_id = auth.uid())
  )
  with check (
    my_role() = 'teacher' and school_id = my_school_id()
    and subject_id in (select s.id from subjects s join teachers t on t.id = s.teacher_id where t.profile_id = auth.uid())
  );

drop policy if exists teacher_manage_own_assessment_scores on assessment_scores;
create policy teacher_manage_own_assessment_scores on assessment_scores for all
  using (my_role() = 'teacher' and school_id = my_school_id() and fn_teaches_student(student_id))
  with check (my_role() = 'teacher' and school_id = my_school_id() and fn_teaches_student(student_id));

-- ---------- Fix 2: schools need a real subscription state + two-way toggle ----------
-- `is_active` already exists (001) and stays the single source of truth for
-- "can anyone at this school log in" (see auth.js's login-time check, added
-- alongside this migration). `subscription_status` is additional, separate
-- from is_active: a school can be `active` and still get suspended, and the
-- platform owner needs to see which of the two it is at a glance.
alter table schools add column if not exists subscription_status text
  not null default 'active'
  check (subscription_status in ('trial', 'active', 'suspended'));

-- Every school that already exists today is a real, already-onboarded
-- tenant, not a fresh trial signup — the default above correctly leaves
-- them at 'active'. Only schools created via the new self-service
-- register-school Edge Function start at 'trial' (set explicitly there).
