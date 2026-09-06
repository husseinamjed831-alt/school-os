-- ============================================================
-- School OS — 013: tenant-security foundation (V1 Phase 2, migration M1)
-- Depends on: 001, 002 (my_role/my_school_id/my_branch_id/is_super_admin),
--   004 (fn_teaches_student), 012 (enforce_row_tenant).
--
-- Scope decision for V1: every user belongs to exactly ONE school via
-- profiles.school_id, so `current_school_id()` is a thin canonical wrapper
-- over my_school_id(). The `tenant_memberships` table + a JWT school_id
-- claim fast-path (HAMURA_DATABASE_SCHEMA.md §1/§2) are deferred to V2 —
-- they only matter for staff who act across branches/schools, which V1
-- does not support. Documented, not a contradiction.
--
-- Rollback: sql/013_tenant_security_rollback.sql
-- Tests:    sql/tests/013_isolation.sql
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. current_school_id() — the canonical tenant resolver every new
--    policy / SECDEF function must use. V1 = my_school_id().
-- ------------------------------------------------------------
create or replace function public.current_school_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select public.my_school_id()
$$;

revoke execute on function public.current_school_id() from public;
grant  execute on function public.current_school_id() to authenticated, service_role;

-- ------------------------------------------------------------
-- 2. school_is_operational() — used by write-policy WITH CHECK from
--    Phase 7 (subscription enforcement). Defined now so later migrations
--    only add the predicate, not the function. V1 semantics: the school
--    row is active. (subscription_status gate added in 019.)
-- ------------------------------------------------------------
create or replace function public.school_is_operational(p_school uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select s.is_active
       and s.subscription_status is distinct from 'suspended'
     from public.schools s where s.id = p_school),
    false)
$$;

revoke execute on function public.school_is_operational(uuid) from public;
grant  execute on function public.school_is_operational(uuid) to authenticated, service_role;

-- ------------------------------------------------------------
-- 3. Re-point enforce_row_tenant() at current_school_id() (identical
--    behaviour today; keeps one canonical source).
-- ------------------------------------------------------------
create or replace function public.enforce_row_tenant()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid;
begin
  if auth.uid() is null then
    return new;                         -- service_role / unauthenticated
  end if;
  if coalesce(is_super_admin(), false) then
    return new;                         -- platform operator
  end if;

  v_school := public.current_school_id();
  if v_school is null then
    raise exception
      'تعذّر تحديد المدرسة لحسابك — لا يمكن إنشاء سجلات بدون سياق مدرسة'
      using errcode = '42501';
  end if;

  new.school_id := v_school;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- 4. Tighten teacher_read_students — probe 5 confirmed a teacher can
--    currently read EVERY student in the school. Restrict to students
--    the teacher actually teaches (via fn_teaches_student, added in 004).
-- ------------------------------------------------------------
drop policy if exists teacher_read_students on public.students;
create policy teacher_read_students on public.students
  for select
  using (
    my_role() = 'teacher'
    and school_id = current_school_id()
    and fn_teaches_student(id)
  );

commit;
