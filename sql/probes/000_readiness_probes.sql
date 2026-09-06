-- ============================================================
-- HAMURA — Phase 0 readiness probes (READ-ONLY / non-destructive)
-- Run in Supabase SQL Editor. Nothing here changes schema or data:
-- the only write is a single INSERT executed inside an explicitly
-- ROLLED BACK transaction, purely to observe whether RLS/triggers
-- would have allowed it.
--
-- Probes 3 & 4 need no parameters — run them as-is.
-- Probes 1, 2, 5b need a real user id / school ids — see the
-- :params at the top of each section.
-- Paste the result of each SELECT back into
-- docs/HAMURA_V1_IMPLEMENTATION_STATUS.md > "Phase 0 probe findings".
-- ============================================================


-- ------------------------------------------------------------
-- PROBE 3  (T-ISO-WITHCHECK-1)  — RLS USING / WITH CHECK coverage
-- Pure catalog query. Lists every policy on a table that has a
-- school_id column, flagging ones whose WITH CHECK is absent or
-- does not reference a tenant predicate.
-- ------------------------------------------------------------
select
  p.schemaname,
  p.tablename,
  p.policyname,
  p.cmd,
  (p.qual is not null)                                   as has_using,
  (p.with_check is not null)                             as has_with_check,
  (coalesce(p.qual,'')       ~* 'my_school_id|is_super_admin|current_school_id') as using_has_tenant,
  (coalesce(p.with_check,'') ~* 'my_school_id|is_super_admin|current_school_id') as check_has_tenant,
  case
    when p.cmd in ('ALL','UPDATE','INSERT')
     and p.with_check is null                               then 'MISSING_WITH_CHECK'
    when p.cmd in ('ALL','UPDATE','INSERT')
     and coalesce(p.with_check,'') !~* 'my_school_id|is_super_admin|current_school_id'
                                                            then 'WITH_CHECK_NO_TENANT'
    when p.cmd in ('ALL','SELECT','UPDATE','DELETE')
     and coalesce(p.qual,'')       !~* 'my_school_id|is_super_admin|current_school_id|auth.uid|profile_id|parent_id|student_id'
                                                            then 'USING_NO_SCOPE'
    else 'ok'
  end                                                    as verdict
from pg_policies p
join information_schema.columns c
  on c.table_schema = p.schemaname
 and c.table_name   = p.tablename
 and c.column_name  = 'school_id'
where p.schemaname = 'public'
order by verdict desc, p.tablename, p.policyname;


-- ------------------------------------------------------------
-- PROBE 4  (T-AUDIT-COVERAGE-1)  — which tenant tables are NOT audited
-- Pure catalog query. Expect (per freeze §4): schools, branches,
-- academic_years, teachers, subjects, schedule, notifications, fees,
-- assessment_types, grading_scales, telegram_link_codes.
-- ------------------------------------------------------------
with tenant_tables as (
  select c.table_name
  from information_schema.columns c
  where c.table_schema = 'public' and c.column_name = 'school_id'
),
audited as (
  select distinct tg.event_object_table as table_name
  from information_schema.triggers tg
  where tg.trigger_schema = 'public'
    and tg.action_statement ilike '%audit.log_change%'
)
select t.table_name,
       (a.table_name is not null) as is_audited
from tenant_tables t
left join audited a using (table_name)
order by is_audited, t.table_name;


-- ------------------------------------------------------------
-- PROBE 5a  (T-ISO-TEACHER-1, catalog part) — is teacher student-read school-wide?
-- Expect to see `teacher_read_students` with a qual that is just
-- my_role()='teacher' AND school_id=my_school_id()  (i.e. NO section scope).
-- ------------------------------------------------------------
select policyname, cmd, qual
from pg_policies
where schemaname='public' and tablename='students'
order by policyname;


-- ============================================================
-- The following need parameters. Set them, then run each block
-- inside its BEGIN/ROLLBACK so nothing persists.
-- Get a real user id:  select id, role, school_id from profiles order by created_at limit 20;
-- ============================================================

-- ------------------------------------------------------------
-- PROBE 1  (T-PRIVESC-SELFROLE-1) — can a non-admin escalate their own profile?
-- :teacher_uid  = a profiles.id whose role is 'teacher' (or any non-admin)
-- ------------------------------------------------------------
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":":teacher_uid","role":"authenticated"}';

  -- attempt 1: become school_admin
  do $$
  begin
    update public.profiles set role = 'school_admin' where id = ':teacher_uid';
    raise notice 'PROBE1a: UPDATE role -> school_admin SUCCEEDED (%). VULNERABLE.', (select role from public.profiles where id=':teacher_uid');
  exception when others then
    raise notice 'PROBE1a: UPDATE role blocked: % / %', SQLSTATE, SQLERRM;
  end $$;

  -- attempt 2: move to another school
  do $$
  begin
    update public.profiles set school_id = gen_random_uuid() where id = ':teacher_uid';
    raise notice 'PROBE1b: UPDATE school_id SUCCEEDED. VULNERABLE.';
  exception when others then
    raise notice 'PROBE1b: UPDATE school_id blocked: % / %', SQLSTATE, SQLERRM;
  end $$;

  -- attempt 3: self-activate
  do $$
  begin
    update public.profiles set is_active = true, activation_status = 'active' where id = ':teacher_uid';
    raise notice 'PROBE1c: UPDATE is_active/activation_status SUCCEEDED (expected for is_active; activation_status is the concern).';
  exception when others then
    raise notice 'PROBE1c blocked: % / %', SQLSTATE, SQLERRM;
  end $$;
rollback;


-- ------------------------------------------------------------
-- PROBE 2  (T-ISO-INSERT-SPOOF-1) — can an admin of school A create a row owned by school B?
-- :admin_uid   = a profiles.id whose role is 'school_admin'
-- :other_school = any schools.id that is NOT that admin's school
-- ------------------------------------------------------------
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":":admin_uid","role":"authenticated"}';

  do $$
  declare v_id uuid;
  begin
    insert into public.students (school_id, full_name)
    values (':other_school', 'PROBE2 spoof - should not exist')
    returning id into v_id;
    raise notice 'PROBE2: INSERT students with foreign school_id SUCCEEDED (id=%). VULNERABLE.', v_id;
  exception when others then
    raise notice 'PROBE2: INSERT foreign-tenant student blocked: % / %', SQLSTATE, SQLERRM;
  end $$;

  do $$
  declare v_id uuid;
  begin
    insert into public.branches (school_id, name)
    values (':other_school', 'PROBE2 spoof branch')
    returning id into v_id;
    raise notice 'PROBE2b: INSERT branches with foreign school_id SUCCEEDED. VULNERABLE.';
  exception when others then
    raise notice 'PROBE2b: blocked: % / %', SQLSTATE, SQLERRM;
  end $$;
rollback;


-- ------------------------------------------------------------
-- PROBE 5b  (T-ISO-TEACHER-1, behavioural) — how many students can a teacher read?
-- :teacher_uid = a profiles.id whose role is 'teacher'
-- Compare "visible to teacher" vs "students in sections they actually teach".
-- ------------------------------------------------------------
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":":teacher_uid","role":"authenticated"}';

  select
    (select count(*) from public.students)                                   as students_visible_to_teacher,
    (select count(*) from public.students s
       where exists (
         select 1 from public.sections sec
         join public.subjects sub on sub.class_id = sec.class_id
         join public.teachers t on t.id = sub.teacher_id
         where sec.id = s.section_id and t.profile_id = ':teacher_uid'
       ))                                                                     as students_teacher_actually_teaches,
    (select count(*) from public.students s
       where s.school_id = (select school_id from public.profiles where id = ':teacher_uid')) as students_in_school;
rollback;
