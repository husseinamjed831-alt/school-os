-- ============================================================
-- School OS — 005: flexible assessments & grading
-- Depends on: 001 (schools/subjects/students), 002 (my_role(),
--   my_school_id()), 003 (audit.log_change()), 004 (fn_teaches_student() —
--   used by the teacher_manage_own_assessment_scores policy)
--
-- Supersedes the hardcoded exam_type enum on the old `grades` table
-- from 001_schema.sql. `grades` is left in place (untouched, per the
-- "don't edit old migrations" rule) but is no longer written to by
-- the app from this point on — assessment_scores replaces it.
-- ============================================================

-- ---------- Assessment types: school-configurable weighting ----------
-- e.g. "واجب" 10%, "اختبار قصير" 20%, "نصف الفصل" 30%, "نهائي" 40%.
-- Weights are NOT enforced to sum to 100 at the DB level (a school may
-- have several concurrent grading tracks); the UI shows a running total
-- per grade_level so an admin can catch a misconfiguration before saving.
create table assessment_types (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  name text not null,
  weight_percent numeric(5,2) not null check (weight_percent >= 0 and weight_percent <= 100),
  grade_level int,                    -- null = applies to every grade level
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, name, grade_level)
);
create index assessment_types_school_idx on assessment_types(school_id);

-- ---------- Grading scales: percent -> label (e.g. "ناجح", "A") ----------
create table grading_scales (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  label text not null,
  min_percent numeric(5,2) not null,
  max_percent numeric(5,2) not null,
  color text,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  check (min_percent <= max_percent)
);
create index grading_scales_school_idx on grading_scales(school_id);

-- ---------- Assessments: one graded event (a specific quiz/exam/assignment) ----------
create table assessments (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  subject_id uuid not null references subjects(id) on delete cascade,
  assessment_type_id uuid not null references assessment_types(id) on delete restrict,
  title text not null,
  max_score numeric(6,2) not null default 100,
  assessment_date date not null default current_date,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index assessments_school_idx on assessments(school_id);
create index assessments_subject_idx on assessments(subject_id);

-- ---------- Assessment scores: one student's result on one assessment ----------
create table assessment_scores (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  assessment_id uuid not null references assessments(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  score numeric(6,2),                 -- null = not graded yet
  is_missing boolean not null default false,
  graded_by uuid references profiles(id),
  graded_at timestamptz,
  created_at timestamptz not null default now(),
  unique (assessment_id, student_id),
  check (score is null or is_missing = false)
);
create index assessment_scores_school_idx on assessment_scores(school_id);
create index assessment_scores_student_idx on assessment_scores(student_id);

-- ============================================================
-- RLS
-- ============================================================
alter table assessment_types enable row level security;
alter table grading_scales enable row level security;
alter table assessments enable row level security;
alter table assessment_scores enable row level security;

-- assessment_types: admins manage; anyone in the school can read (needed to
-- render weighted breakdowns on Student 360 / dashboards).
create policy super_admin_all_assessment_types on assessment_types for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_assessment_types on assessment_types for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy read_own_school_assessment_types on assessment_types for select
  using (school_id = my_school_id());

-- grading_scales: same pattern.
create policy super_admin_all_grading_scales on grading_scales for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_grading_scales on grading_scales for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy read_own_school_grading_scales on grading_scales for select
  using (school_id = my_school_id());

-- assessments: admins full access; teacher can manage only for subjects they
-- teach; students/parents read assessments for subjects tied to their own
-- (or their child's) section only.
create policy super_admin_all_assessments on assessments for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_assessments on assessments for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_assessments on assessments for all
  using (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and subject_id in (select id from subjects where class_id in (select id from classes where branch_id = my_branch_id()))
  )
  with check (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and subject_id in (select id from subjects where class_id in (select id from classes where branch_id = my_branch_id()))
  );
create policy teacher_manage_own_assessments on assessments for all
  using (
    my_role() = 'teacher'
    and subject_id in (select s.id from subjects s join teachers t on t.id = s.teacher_id where t.profile_id = auth.uid())
  )
  with check (
    my_role() = 'teacher'
    and subject_id in (select s.id from subjects s join teachers t on t.id = s.teacher_id where t.profile_id = auth.uid())
  );
create policy student_read_own_assessments on assessments for select
  using (
    my_role() = 'student'
    and subject_id in (
      select sub.id from subjects sub
      join classes c on c.id = sub.class_id
      join sections sec on sec.class_id = c.id
      join students st on st.section_id = sec.id
      where st.profile_id = auth.uid()
    )
  );
create policy parent_read_children_assessments on assessments for select
  using (
    my_role() = 'parent'
    and subject_id in (
      select sub.id from subjects sub
      join classes c on c.id = sub.class_id
      join sections sec on sec.class_id = c.id
      join students st on st.section_id = sec.id
      where st.parent_id = auth.uid()
    )
  );

-- assessment_scores: same shape as assessments, but scoped by student.
create policy super_admin_all_assessment_scores on assessment_scores for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_assessment_scores on assessment_scores for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_assessment_scores on assessment_scores for all
  using (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  )
  with check (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  );
create policy teacher_manage_own_assessment_scores on assessment_scores for all
  using (my_role() = 'teacher' and fn_teaches_student(student_id))
  with check (my_role() = 'teacher' and fn_teaches_student(student_id));
create policy student_own_assessment_scores on assessment_scores for select
  using (student_id in (select id from students where profile_id = auth.uid()));
create policy parent_children_assessment_scores on assessment_scores for select
  using (student_id in (select id from students where parent_id = auth.uid()));

-- ---------- Audit ----------
create trigger audit_assessment_scores after insert or update or delete on assessment_scores
  for each row execute function audit.log_change();
create trigger audit_assessments after insert or update or delete on assessments
  for each row execute function audit.log_change();
