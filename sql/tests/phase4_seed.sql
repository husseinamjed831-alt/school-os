-- ============================================================
-- School OS — Phase 4 test seed
-- Depends on: 001-007 all applied.
-- Run in the Supabase SQL Editor (or psql) — no CLI-only syntax used,
-- unlike phase4_rls_tests.sql.
--
-- Creates two separate tenants with FIXED, hardcoded UUIDs so this script
-- and sql/tests/phase4_rls_tests.sql can reference the exact same rows —
-- no copying IDs between the two by hand.
--
-- School A (the main dataset): 1 branch, 1 academic year, 2 classes,
--   2 sections, 2 teachers, 4 students, 2 parents.
-- School B (isolation control): 1 branch, 1 academic year, 1 class,
--   1 section, 1 teacher, 1 student. Its only purpose is proving School A
--   can never see it and vice versa.
--
-- All data is fake/test-only — every email ends in @test.schoolos.local,
-- every password is the literal string below. Do not reuse this password
-- anywhere real.
--
--   TEST PASSWORD FOR EVERY SEEDED ACCOUNT:  Test1234!
--
-- Safe to re-run: PART 0 deletes anything this script created before,
-- by the same fixed IDs, so running it twice leaves the same end state.
-- ============================================================

-- ============================================================
-- PART 0 — cleanup (idempotent re-run)
-- ============================================================
delete from auth.users where id in (
  'a1000000-0000-0000-0000-0000000000a1', -- school_admin_a
  'a1000000-0000-0000-0000-0000000000a2', -- branch_admin_a
  'a1000000-0000-0000-0000-0000000000a3', -- teacher_a1
  'a1000000-0000-0000-0000-0000000000a4', -- teacher_a2
  'a1000000-0000-0000-0000-0000000000a5', -- parent_a1
  'a1000000-0000-0000-0000-0000000000a6', -- parent_a2
  'a1000000-0000-0000-0000-0000000000a7', -- student_a1 (has a login)
  'b2000000-0000-0000-0000-0000000000a1', -- school_admin_b
  'b2000000-0000-0000-0000-0000000000a2', -- teacher_b1
  'b2000000-0000-0000-0000-0000000000a3'  -- student_b1 (has a login)
);
-- Cascades: auth.users -> profiles (on delete cascade) -> auth.identities
-- (on delete cascade from auth.users). Deleting the schools below cascades
-- to branches/years/classes/sections/students/subjects/teachers rows too.
delete from schools where id in (
  'a1000000-0000-0000-0000-000000000001',
  'b2000000-0000-0000-0000-000000000001'
);

-- ============================================================
-- PART 1 — auth accounts (real logins, password: Test1234!)
--
-- This uses the well-known "insert directly into auth.users +
-- auth.identities" pattern for seeding test accounts without going
-- through the Auth API. It has worked unchanged across Supabase Auth
-- versions for a long time, but Supabase does not treat auth.* as a
-- versioned public API — if this section errors with a column mismatch,
-- your project's Auth schema differs slightly from what's assumed here.
--
-- FALLBACK if PART 1 errors: create the same 10 accounts by hand in
-- Supabase Studio -> Authentication -> Users -> Add User (check "Auto
-- Confirm User", use the emails/password above), then find each new
-- user's id (Authentication -> Users, click the row) and replace the
-- matching placeholder ID in PART 2 below with the real one before
-- running PART 2. PART 2 has no auth.* dependency and always works.
-- ============================================================

do $$
declare
  v_password text := crypt('Test1234!', gen_salt('bf'));
  v_users jsonb := '[
    {"id":"a1000000-0000-0000-0000-0000000000a1","email":"school_admin_a@test.schoolos.local"},
    {"id":"a1000000-0000-0000-0000-0000000000a2","email":"branch_admin_a@test.schoolos.local"},
    {"id":"a1000000-0000-0000-0000-0000000000a3","email":"teacher_a1@test.schoolos.local"},
    {"id":"a1000000-0000-0000-0000-0000000000a4","email":"teacher_a2@test.schoolos.local"},
    {"id":"a1000000-0000-0000-0000-0000000000a5","email":"parent_a1@test.schoolos.local"},
    {"id":"a1000000-0000-0000-0000-0000000000a6","email":"parent_a2@test.schoolos.local"},
    {"id":"a1000000-0000-0000-0000-0000000000a7","email":"student_a1@test.schoolos.local"},
    {"id":"b2000000-0000-0000-0000-0000000000a1","email":"school_admin_b@test.schoolos.local"},
    {"id":"b2000000-0000-0000-0000-0000000000a2","email":"teacher_b1@test.schoolos.local"},
    {"id":"b2000000-0000-0000-0000-0000000000a3","email":"student_b1@test.schoolos.local"}
  ]';
  v_user jsonb;
begin
  for v_user in select * from jsonb_array_elements(v_users)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000',
      (v_user->>'id')::uuid,
      'authenticated',
      'authenticated',
      v_user->>'email',
      v_password,
      now(),
      '{"provider":"email","providers":["email"]}',
      '{}',
      now(), now(),
      -- These four MUST be '' and not NULL: GoTrue's Go code scans them into
      -- non-nullable strings during password login, and a NULL here fails
      -- with the unhelpful "Database error querying schema" — confirmed by
      -- hitting exactly this while testing a real login against a live
      -- project. Normal signup always sets '', direct INSERT does not
      -- unless told to.
      '', '', '', ''
    );

    insert into auth.identities (
      id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(),
      (v_user->>'id')::uuid,
      jsonb_build_object('sub', v_user->>'id', 'email', v_user->>'email'),
      'email',
      v_user->>'id',
      now(), now(), now()
    );
  end loop;
end $$;

-- ============================================================
-- PART 2 — everything else (schools, structure, profiles, links)
-- Safe standard SQL — no auth.* fragility.
-- ============================================================

-- ---------- School A ----------
insert into schools (id, name, slug) values
  ('a1000000-0000-0000-0000-000000000001', 'مدرسة الاختبار أ (لا تستخدم بيانات حقيقية)', 'test-school-a');

insert into branches (id, school_id, name) values
  ('a1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'الفرع الرئيسي');

insert into academic_years (id, school_id, label, starts_on, ends_on, is_current) values
  ('a1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', '2026-2027', '2026-09-01', '2027-06-30', true);

insert into classes (id, school_id, branch_id, academic_year_id, grade_level, name) values
  ('a1000000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000003', 7, 'الأول متوسط'),
  ('a1000000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000003', 8, 'الثاني متوسط');

insert into sections (id, school_id, class_id, name, capacity) values
  ('a1000000-0000-0000-0000-000000000021', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000011', 'أ', 30),
  ('a1000000-0000-0000-0000-000000000022', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000012', 'أ', 30);

-- profiles for School A's 7 accounts
insert into profiles (id, school_id, branch_id, role, full_name, phone) values
  ('a1000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-000000000001', null, 'school_admin', 'مدير مدرسة أ (اختبار)', null),
  ('a1000000-0000-0000-0000-0000000000a2', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'branch_admin', 'مدير فرع أ (اختبار)', null),
  ('a1000000-0000-0000-0000-0000000000a3', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'teacher', 'معلم أ 1 (اختبار)', null),
  ('a1000000-0000-0000-0000-0000000000a4', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'teacher', 'معلم أ 2 (اختبار)', null),
  ('a1000000-0000-0000-0000-0000000000a5', 'a1000000-0000-0000-0000-000000000001', null, 'parent', 'ولي أمر أ 1 (اختبار)', null),
  ('a1000000-0000-0000-0000-0000000000a6', 'a1000000-0000-0000-0000-000000000001', null, 'parent', 'ولي أمر أ 2 (اختبار)', null),
  ('a1000000-0000-0000-0000-0000000000a7', 'a1000000-0000-0000-0000-000000000001', null, 'student', 'طالب أ 1 (اختبار، له حساب دخول)', null);

insert into teachers (id, school_id, branch_id, profile_id) values
  ('a1000000-0000-0000-0000-0000000000b1', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-0000000000a3'),
  ('a1000000-0000-0000-0000-0000000000b2', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-0000000000a4');

-- Subjects are what makes teacher-scoping (fn_teaches_section/fn_teaches_student)
-- resolve to anything — without these, both teachers would appear to teach
-- nobody, and the RLS "teacher isolation" tests would have nothing to test.
insert into subjects (id, school_id, class_id, teacher_id, name) values
  ('a1000000-0000-0000-0000-0000000000c1', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000011', 'a1000000-0000-0000-0000-0000000000b1', 'الرياضيات'),
  ('a1000000-0000-0000-0000-0000000000c2', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000012', 'a1000000-0000-0000-0000-0000000000b2', 'العلوم');

-- 4 students: student_a1 has a login + is in section 1 with parent_a1;
-- student_a2 is also parent_a1's (tests a parent with 2 children), in
-- section 1, no login; student_a3 is parent_a2's, section 2; student_a4
-- has no parent linked at all (tests the "no parent" empty state).
insert into students (id, school_id, branch_id, profile_id, parent_id, section_id, full_name, birth_date) values
  ('a1000000-0000-0000-0000-0000000000d1', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-0000000000a7', 'a1000000-0000-0000-0000-0000000000a5', 'a1000000-0000-0000-0000-000000000021', 'طالب أ 1 (اختبار)', '2013-03-10'),
  ('a1000000-0000-0000-0000-0000000000d2', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', null,                                     'a1000000-0000-0000-0000-0000000000a5', 'a1000000-0000-0000-0000-000000000021', 'طالب أ 2 (اختبار)', '2013-07-22'),
  ('a1000000-0000-0000-0000-0000000000d3', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', null,                                     'a1000000-0000-0000-0000-0000000000a6', 'a1000000-0000-0000-0000-000000000022', 'طالب أ 3 (اختبار)', '2012-11-05'),
  ('a1000000-0000-0000-0000-0000000000d4', 'a1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002', null,                                     null,                                     'a1000000-0000-0000-0000-000000000022', 'طالب أ 4 (اختبار)', '2012-09-18');

-- ---------- School B (isolation control — kept minimal on purpose) ----------
insert into schools (id, name, slug) values
  ('b2000000-0000-0000-0000-000000000001', 'مدرسة الاختبار ب (لا تستخدم بيانات حقيقية)', 'test-school-b');

insert into branches (id, school_id, name) values
  ('b2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000001', 'الفرع الرئيسي');

insert into academic_years (id, school_id, label, starts_on, ends_on, is_current) values
  ('b2000000-0000-0000-0000-000000000003', 'b2000000-0000-0000-0000-000000000001', '2026-2027', '2026-09-01', '2027-06-30', true);

insert into classes (id, school_id, branch_id, academic_year_id, grade_level, name) values
  ('b2000000-0000-0000-0000-000000000011', 'b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000003', 7, 'الأول متوسط');

insert into sections (id, school_id, class_id, name, capacity) values
  ('b2000000-0000-0000-0000-000000000021', 'b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000011', 'أ', 30);

insert into profiles (id, school_id, branch_id, role, full_name) values
  ('b2000000-0000-0000-0000-0000000000a1', 'b2000000-0000-0000-0000-000000000001', null, 'school_admin', 'مدير مدرسة ب (اختبار)'),
  ('b2000000-0000-0000-0000-0000000000a2', 'b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', 'teacher', 'معلم ب 1 (اختبار)'),
  ('b2000000-0000-0000-0000-0000000000a3', 'b2000000-0000-0000-0000-000000000001', null, 'student', 'طالب ب 1 (اختبار، له حساب دخول)');

insert into teachers (id, school_id, branch_id, profile_id) values
  ('b2000000-0000-0000-0000-0000000000b1', 'b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-0000000000a2');

insert into subjects (id, school_id, class_id, teacher_id, name) values
  ('b2000000-0000-0000-0000-0000000000c1', 'b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000011', 'b2000000-0000-0000-0000-0000000000b1', 'الرياضيات');

insert into students (id, school_id, branch_id, profile_id, section_id, full_name, birth_date) values
  ('b2000000-0000-0000-0000-0000000000d1', 'b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-0000000000a3', 'b2000000-0000-0000-0000-000000000021', 'طالب ب 1 (اختبار)', '2013-01-15');

-- ============================================================
-- Done. Reference sheet for phase4_rls_tests.sql and manual login testing:
--
-- School A (school id a1000000-0000-0000-0000-000000000001)
--   school_admin_a@test.schoolos.local   -> school_admin
--   branch_admin_a@test.schoolos.local   -> branch_admin
--   teacher_a1@test.schoolos.local       -> teacher, teaches الرياضيات / section a1000000-...021
--   teacher_a2@test.schoolos.local       -> teacher, teaches العلوم / section a1000000-...022
--   parent_a1@test.schoolos.local        -> parent of student_a1 and student_a2
--   parent_a2@test.schoolos.local        -> parent of student_a3
--   student_a1@test.schoolos.local       -> student, id a1000000-0000-0000-0000-0000000000d1
--
-- School B (school id b2000000-0000-0000-0000-000000000001)
--   school_admin_b@test.schoolos.local   -> school_admin
--   teacher_b1@test.schoolos.local       -> teacher
--   student_b1@test.schoolos.local       -> student, id b2000000-0000-0000-0000-0000000000d1
--
-- Password for every account above: Test1234!
-- ============================================================
