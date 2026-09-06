-- ============================================================
-- School OS — 015 historical-enrollment regression. Run AFTER 015.
-- Non-destructive (BEGIN ... ROLLBACK). Fixtures from the prod seed:
--   student d1 = a1000000-0000-0000-0000-0000000000d1  (test-school-a, active enr, section ...021)
--   enr    d1 = <look up>  ;  sections ...021 / ...022
-- Verified live 2026-09-06.
-- ============================================================

-- BACKFILL-CONSISTENCY : every active enrollment's snapshot section == students.section_id
select 'T-COMPAT-SECTION-BACKFILL' as t,
  case when (select count(*) from public.enrollment_snapshot es
              join public.students st on st.id = es.student_id
              where st.section_id is distinct from es.section_id) = 0
       then 'PASS' else 'FAIL' end as result;

-- 1:1 : one enrollment per active student, none for inactive
select 'T-ENROLL-CARDINALITY' as t,
  case when (select count(*) from public.enrollments) =
            (select count(*) from public.students where is_active)
       then 'PASS' else 'FAIL' end as result;

-- MIRROR-5a : direct students.section_id UPDATE creates a section_assignments transition
begin;
  update public.students set section_id = 'a1000000-0000-0000-0000-000000000022'
   where id = 'a1000000-0000-0000-0000-0000000000d1';
  select 'T-COMPAT-SECTION-1a' as t,
    case when (select section_id from public.enrollment_snapshot where student_id='a1000000-0000-0000-0000-0000000000d1')
              = 'a1000000-0000-0000-0000-000000000022'
         and (select count(*) from public.section_assignments sa
                join public.enrollments e on e.id = sa.enrollment_id
                where e.student_id='a1000000-0000-0000-0000-0000000000d1' and sa.to_date is null) = 1
         then 'PASS' else 'FAIL' end as result;
rollback;

-- FREEZE : an active enrollment's placement cannot be edited directly
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
  do $$
  begin
    update public.enrollments set class_id = 'a1000000-0000-0000-0000-000000000012'
      where student_id='a1000000-0000-0000-0000-0000000000d1' and state='active';
    drop table if exists _z; create temp table _z(r text); insert into _z values ('FAIL: direct placement update allowed');
  exception when sqlstate '42501' then
    drop table if exists _z; create temp table _z(r text); insert into _z values ('PASS');
  end $$;
  select 'T-ENROLL-HISTORY-1' as t, r as result from _z;
rollback;
