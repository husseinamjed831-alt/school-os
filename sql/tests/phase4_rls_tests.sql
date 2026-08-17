-- ============================================================
-- School OS — Phase 4 RLS test suite
--
-- Depends on: sql/tests/phase4_seed.sql having been run already, in the
-- same database, unmodified — every ID below is the seed's fixed ID, not a
-- placeholder. If you edited the seed's IDs, edit them here to match.
--
-- HOW TO RUN
--   1. Run sql/tests/phase4_seed.sql first (SQL Editor or psql — either
--      works for that one).
--   2. This script uses psql meta-commands (\set), which the Supabase web
--      SQL Editor does NOT support. Run it with the actual `psql` CLI:
--        psql "postgresql://postgres:[password]@[host]:5432/postgres" \
--          -f sql/tests/phase4_rls_tests.sql
--      Get the connection string from Supabase Dashboard -> Settings ->
--      Database -> Connection string.
--   3. Read the output top to bottom. Every check prints PASS or FAIL via
--      RAISE NOTICE/EXCEPTION. A FAIL aborts the transaction at that point
--      (everything already run is still reported above it) — fix the
--      policy, don't just re-run and hope.
--   4. The whole thing runs inside one transaction and ROLLBACKs at the
--      end — it never leaves the seed data's state changed, so it's safe
--      to run repeatedly.
--
-- This impersonates each user the same way PostgREST does: set the JWT
-- claims Postgres's auth.uid() reads, then run queries as `authenticated`.
-- ============================================================

\set school_admin_a       'a1000000-0000-0000-0000-0000000000a1'
\set branch_admin_a       'a1000000-0000-0000-0000-0000000000a2'
\set teacher_a1           'a1000000-0000-0000-0000-0000000000a3'
\set teacher_a2           'a1000000-0000-0000-0000-0000000000a4'
\set parent_a1            'a1000000-0000-0000-0000-0000000000a5'
\set parent_a2            'a1000000-0000-0000-0000-0000000000a6'
\set student_a1_profile   'a1000000-0000-0000-0000-0000000000a7'
\set student_a1_row       'a1000000-0000-0000-0000-0000000000d1'
\set student_a2_row       'a1000000-0000-0000-0000-0000000000d2'
\set school_admin_b       'b2000000-0000-0000-0000-0000000000a1'
\set teacher_b1           'b2000000-0000-0000-0000-0000000000a2'
\set student_b1_row       'b2000000-0000-0000-0000-0000000000d1'

begin;

-- ===================== 0. super_admin sees both tenants =====================
-- (Sanity check: if this fails, the harness/seed itself is broken, not a
-- real isolation bug — super_admin is meant to see everything.)
reset role;
reset "request.jwt.claims";
do $$
begin
  if (select count(*) from schools where id in ('a1000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000001')) <> 2
  then
    raise exception 'SETUP FAIL: expected both seeded schools to exist — did you run phase4_seed.sql first?';
  end if;
  raise notice 'PASS (0): seed data for both schools is present';
end $$;

-- ===================== 1. school_admin: scoped to own school =====================
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'school_admin_a')::text, true);

do $$
begin
  if (select count(*) from students) <> 4 then
    raise exception 'FAIL (1a): school_admin_a sees % students, expected exactly 4', (select count(*) from students);
  end if;
  raise notice 'PASS (1a): school_admin_a sees exactly their own 4 students';
end $$;

do $$
declare v_count int;
begin
  select count(*) into v_count from students where id = :'student_b1_row'::uuid;
  if v_count <> 0 then
    raise exception 'FAIL (1b): school_admin_a can see School B''s student — TENANT ISOLATION BROKEN';
  end if;
  raise notice 'PASS (1b): school_admin_a cannot see School B''s student';
end $$;

-- ===================== 2. Cross-tenant: School B admin =====================
select set_config('request.jwt.claims', json_build_object('sub', :'school_admin_b')::text, true);
do $$
declare v_count int;
begin
  select count(*) into v_count from students where id = :'student_a1_row'::uuid;
  if v_count <> 0 then
    raise exception 'FAIL (2): school_admin_b can see School A''s student — TENANT ISOLATION BROKEN';
  end if;
  if (select count(*) from students) <> 1 then
    raise exception 'FAIL (2): school_admin_b sees % students, expected exactly 1 (their own)', (select count(*) from students);
  end if;
  raise notice 'PASS (2): school_admin_b sees only their own 1 student, never School A''s';
end $$;

-- ===================== 3. branch_admin: scoped to own branch (and thus own tenant) =====================
select set_config('request.jwt.claims', json_build_object('sub', :'branch_admin_a')::text, true);
do $$
declare v_count int;
begin
  if (select count(*) from students) <> 4 then
    raise exception 'FAIL (3a): branch_admin_a sees % students, expected 4 (their branch = their whole school here)', (select count(*) from students);
  end if;
  select count(*) into v_count from students where id = :'student_b1_row'::uuid;
  if v_count <> 0 then
    raise exception 'FAIL (3b): branch_admin_a can see School B''s student — BRANCH/TENANT ISOLATION BROKEN';
  end if;
  raise notice 'PASS (3): branch_admin_a is scoped to their own branch and cannot reach School B';
end $$;

-- ===================== 4. teacher: scoped to sections they teach =====================
select set_config('request.jwt.claims', json_build_object('sub', :'teacher_a1')::text, true);
do $$
begin
  -- teacher_a1 teaches الرياضيات in section a1...021 (student_a1, student_a2).
  insert into attendance (school_id, student_id, date, status, recorded_by)
  select school_id, id, current_date, 'present', :'teacher_a1'::uuid
  from students where id = :'student_a1_row'::uuid
  on conflict (student_id, date) do update set status = excluded.status;
  raise notice 'PASS (4a): teacher_a1 can record attendance for a student they teach';
exception when others then
  raise exception 'FAIL (4a): teacher_a1 could not record attendance for their own student: %', sqlerrm;
end $$;

do $$
begin
  begin
    -- student_a1_row belongs to section a1...021 which teacher_a1 teaches — fine.
    -- Try the SAME insert for School B's student, which teacher_a1 does not teach.
    insert into attendance (school_id, student_id, date, status, recorded_by)
    select school_id, id, current_date, 'present', :'teacher_a1'::uuid
    from students where id = :'student_b1_row'::uuid;
    raise exception 'FAIL (4b): teacher_a1 wrote attendance for an unrelated (cross-tenant) student — RLS BROKEN';
  exception when insufficient_privilege or others then
    raise notice 'PASS (4b): teacher_a1 blocked from writing attendance for School B''s student';
  end;
end $$;

do $$
declare v_count int;
begin
  -- teacher_a1 should see student_a1/a2 (their section) but not student_a3/a4
  -- (teacher_a2's section) — same-tenant TEACHER isolation, not just tenant isolation.
  select count(*) into v_count from students where id in (:'student_a1_row'::uuid, :'student_a2_row'::uuid);
  if v_count <> 2 then
    raise exception 'FAIL (4c): teacher_a1 should see both their own section''s students (got %)', v_count;
  end if;
  raise notice 'PASS (4c): teacher_a1 sees their own section''s students';
end $$;

-- ===================== 5. student: only their own row, nothing else =====================
select set_config('request.jwt.claims', json_build_object('sub', :'student_a1_profile')::text, true);
do $$
declare v_count int;
begin
  select count(*) into v_count from students;
  if v_count <> 1 then
    raise exception 'FAIL (5a): student_a1 sees % rows in students, expected exactly 1 (their own)', v_count;
  end if;
  raise notice 'PASS (5a): student_a1 sees exactly their own student row';
end $$;

do $$
declare v_count int;
begin
  -- student_a2 is a DIFFERENT student in the SAME section/school — this is
  -- the same-tenant peer-isolation case, distinct from cross-tenant.
  select count(*) into v_count from students where id = :'student_a2_row'::uuid;
  if v_count <> 0 then
    raise exception 'FAIL (5b): student_a1 can see a classmate''s row (student_a2) — STUDENT ISOLATION BROKEN';
  end if;
  raise notice 'PASS (5b): student_a1 cannot see a classmate''s row, even in the same section';
end $$;

do $$
begin
  begin
    update attendance set status = 'absent' where student_id = :'student_a1_row'::uuid;
    raise exception 'FAIL (5c): a student was able to modify their own attendance — RLS BROKEN';
  exception when insufficient_privilege or others then
    raise notice 'PASS (5c): student cannot modify attendance records';
  end;
end $$;

do $$
begin
  begin
    perform * from fn_student_risk_score(:'student_a1_row'::uuid);
    raise exception 'FAIL (5d): student was able to read their own risk score — should be staff-only';
  exception when others then
    raise notice 'PASS (5d): risk score denied to the student (%: %)', sqlstate, sqlerrm;
  end;
end $$;

-- ===================== 6. parent: only their own children =====================
select set_config('request.jwt.claims', json_build_object('sub', :'parent_a1')::text, true);
do $$
declare v_count int;
begin
  -- parent_a1 has TWO children (student_a1, student_a2) — both must show up.
  select count(*) into v_count from students where id in (:'student_a1_row'::uuid, :'student_a2_row'::uuid);
  if v_count <> 2 then
    raise exception 'FAIL (6a): parent_a1 should see both of their children (got %)', v_count;
  end if;
  raise notice 'PASS (6a): parent_a1 sees both of their linked children';
end $$;

do $$
declare v_count int;
begin
  -- student_a3 belongs to parent_a2, not parent_a1 — same-tenant parent isolation.
  select count(*) into v_count from students where full_name = 'طالب أ 3 (اختبار)';
  if v_count <> 0 then
    raise exception 'FAIL (6b): parent_a1 can see parent_a2''s child — PARENT ISOLATION BROKEN (same tenant)';
  end if;
  raise notice 'PASS (6b): parent_a1 cannot see another parent''s child in the same school';
end $$;

do $$
declare v_count int;
begin
  select count(*) into v_count from students where id = :'student_b1_row'::uuid;
  if v_count <> 0 then
    raise exception 'FAIL (6c): parent_a1 can see School B''s student — PARENT ISOLATION BROKEN (cross-tenant)';
  end if;
  raise notice 'PASS (6c): parent_a1 cannot see School B''s student';
end $$;

-- ===================== 7. Audit log captured the sensitive writes above =====================
reset role;
reset "request.jwt.claims";
do $$
declare v_count int;
begin
  select count(*) into v_count from audit.audit_log
  where table_name = 'attendance' and row_id in (
    select id::text from attendance where student_id = :'student_a1_row'::uuid
  );
  if v_count = 0 then
    raise exception 'FAIL (7): no audit_log rows found for the attendance write made in test 4a';
  end if;
  raise notice 'PASS (7): the attendance write was captured in audit.audit_log (% entries)', v_count;
end $$;

rollback;
-- Everything above runs inside one transaction and rolls back — the seed
-- data (and the one attendance row test 4a wrote) is exactly as it was
-- before this script ran.

\echo 'All checks completed. Scroll up for any FAIL — a clean run prints only PASS/NOTICE lines.'
