-- ============================================================
-- School OS — 013/014 cross-tenant isolation + RBAC regression.
-- Run AFTER 013 + 014. Non-destructive (BEGIN ... ROLLBACK).
-- Fixtures (prod seed):
--   test-school-a = a1000000-0000-0000-0000-000000000001
--   test-school-b = b2000000-0000-0000-0000-000000000001
--   A.school_admin = a1000000-0000-0000-0000-0000000000a1 (also school_owner)
--   A.branch_admin = a1000000-0000-0000-0000-0000000000a2
--   A.teacher      = a1000000-0000-0000-0000-0000000000a3  (teaches 2 students)
--   A.parent       = a1000000-0000-0000-0000-0000000000a5
-- Each block's final SELECT returns the verdict row.
-- ============================================================

-- T-ISO-SELECT-1 : School A admin cannot see School B rows
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
  select 'T-ISO-SELECT-1' as t,
    case when (select count(*) from public.students where school_id='b2000000-0000-0000-0000-000000000001') = 0
          and (select count(*) from public.schools) = 1
         then 'PASS' else 'FAIL' end as result;
rollback;

-- T-ISO-INSERT-1 : enforce_row_tenant rewrites a spoofed school_id
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
  do $$
  declare v uuid;
  begin
    insert into public.students(school_id, full_name) values ('b2000000-0000-0000-0000-000000000001','iso test') returning school_id into v;
    drop table if exists _t; create temp table _t(r text);
    insert into _t values (case when v = 'a1000000-0000-0000-0000-000000000001'::uuid then 'PASS' else 'FAIL landed '||v end);
  exception when sqlstate '42501' then
    drop table if exists _t; create temp table _t(r text); insert into _t values ('PASS (rejected)');
  end $$;
  select 'T-ISO-INSERT-1' as t, r as result from _t;
rollback;

-- T-ISO-TEACHER-1 : teacher sees only students they teach
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a3","role":"authenticated"}';
  select 'T-ISO-TEACHER-1' as t,
    case when (select count(*) from public.students) =
              (select count(*) from public.students s where public.fn_teaches_student(s.id))
         then 'PASS' else 'FAIL' end as result,
    (select count(*) from public.students) as visible;
rollback;

-- T-ISO-PARENT-1 : parent sees only their children
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a5","role":"authenticated"}';
  select 'T-ISO-PARENT-1' as t,
    case when (select count(*) from public.students s where s.parent_id <> 'a1000000-0000-0000-0000-0000000000a5') = 0
         then 'PASS' else 'FAIL' end as result;
rollback;

-- T-PRIVESC-GRANT-1 : branch_admin cannot grant school_admin
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a2","role":"authenticated"}';
  do $$
  begin
    perform public.assign_role('a1000000-0000-0000-0000-0000000000a4','school_admin','SCHOOL',null);
    drop table if exists _g; create temp table _g(r text); insert into _g values ('FAIL: grant succeeded');
  exception when others then
    drop table if exists _g; create temp table _g(r text); insert into _g values ('PASS ('||SQLSTATE||')');
  end $$;
  select 'T-PRIVESC-GRANT-1' as t, r as result from _g;
rollback;
