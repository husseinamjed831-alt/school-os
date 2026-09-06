-- ============================================================
-- School OS — 015: historical enrollment (V1 Phase 3, migration M3)
-- Depends on: 001, 002, 003 (audit), 004 (fn_teaches_student), 012
--   (enforce_row_tenant), 013 (current_school_id).
--
-- P0-1: `students.section_id` stops being the source of truth for a
-- student's academic placement. It is KEPT and bidirectionally mirrored
-- with `section_assignments` for a compatibility window; it is dropped
-- only by a later gated contract migration (see HAMURA_MIGRATION_PLAN.md
-- §3). Promotion/transfer/withdrawal/graduation are enrollment ops that
-- never destroy history.
--
-- Rollback: sql/015_enrollment_rollback.sql   Tests: sql/tests/015_enrollment.sql
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0. Preconditions: a current academic_year for every school with
--    active students. Create an audited placeholder where missing.
-- ------------------------------------------------------------
insert into public.academic_years (school_id, label, starts_on, ends_on, is_current)
select s.id,
       'ترحيل ' || to_char(current_date,'YYYY'),
       date_trunc('year', current_date)::date,
       (date_trunc('year', current_date) + interval '1 year - 1 day')::date,
       true
from public.schools s
where exists (select 1 from public.students st where st.school_id = s.id and st.is_active)
  and not exists (select 1 from public.academic_years ay where ay.school_id = s.id and ay.is_current);

-- ------------------------------------------------------------
-- 1. Lookups
-- ------------------------------------------------------------
create table if not exists public.grade_levels (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  name       text not null,
  ordinal    int  not null,
  stage      text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  unique (school_id, ordinal)
);
create index if not exists grade_levels_school_idx on public.grade_levels(school_id);

create table if not exists public.academic_terms (
  id               uuid primary key default gen_random_uuid(),
  school_id        uuid not null references public.schools(id) on delete cascade,
  academic_year_id uuid not null references public.academic_years(id) on delete cascade,
  name             text not null,
  starts_on        date,
  ends_on          date,
  sequence         int  not null default 1,
  is_current       boolean not null default false,
  created_at       timestamptz not null default now(),
  unique (academic_year_id, sequence)
);
create index if not exists academic_terms_school_idx on public.academic_terms(school_id);

create table if not exists public.school_settings (
  school_id  uuid primary key references public.schools(id) on delete cascade,
  term_mode  text not null default 'year_only' check (term_mode in ('year_only','semesters','quarters')),
  attendance_locks_after_days int not null default 3,
  settings   jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- backfill grade_levels from distinct classes.grade_level per school
insert into public.grade_levels (school_id, name, ordinal)
select distinct c.school_id, 'المرحلة ' || c.grade_level, c.grade_level
from public.classes c
where not exists (select 1 from public.grade_levels g where g.school_id = c.school_id and g.ordinal = c.grade_level);

-- one school_settings row per school
insert into public.school_settings (school_id)
select id from public.schools
on conflict (school_id) do nothing;

-- ------------------------------------------------------------
-- 2. enrollments  (LIFECYCLE + VERSIONED; never hard-deleted once active)
-- ------------------------------------------------------------
create table if not exists public.enrollments (
  id                  uuid primary key default gen_random_uuid(),
  school_id           uuid not null references public.schools(id) on delete restrict,
  student_id          uuid not null references public.students(id) on delete restrict,
  academic_year_id    uuid not null references public.academic_years(id) on delete restrict,
  branch_id           uuid references public.branches(id) on delete set null,
  program_id          uuid,
  grade_level_id      uuid references public.grade_levels(id) on delete set null,
  class_id            uuid references public.classes(id) on delete set null,
  student_category_id uuid,
  enrolled_on         date not null default current_date,
  state               text not null default 'draft'
                        check (state in ('draft','active','completed','withdrawn','transferred_out')),
  result              text check (result in ('promoted','retained','graduated','withdrawn','transferred')),
  ended_on            date,
  end_reason          text,
  prev_enrollment_id  uuid references public.enrollments(id) on delete set null,
  next_enrollment_id  uuid references public.enrollments(id) on delete set null,
  promotion_run_id    uuid,
  version             int not null default 1,
  created_at          timestamptz not null default now(),
  created_by          uuid references public.profiles(id) on delete set null,
  updated_at          timestamptz not null default now(),
  updated_by          uuid references public.profiles(id) on delete set null
);
create index if not exists enrollments_student_idx on public.enrollments(student_id);
create index if not exists enrollments_school_idx  on public.enrollments(school_id);
create unique index if not exists enrollments_one_per_year
  on public.enrollments(student_id, academic_year_id) where state <> 'withdrawn';

create table if not exists public.section_assignments (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  section_id    uuid references public.sections(id) on delete set null,
  from_date     date not null default current_date,
  to_date       date,
  reason        text,
  assigned_by   uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists section_assignments_enr_idx on public.section_assignments(enrollment_id);

create table if not exists public.enrollment_versions (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  version       int not null,
  snapshot      jsonb not null,
  changed_by    uuid references public.profiles(id) on delete set null,
  changed_at    timestamptz not null default now(),
  reason        text
);

-- ------------------------------------------------------------
-- 3. RLS
-- ------------------------------------------------------------
alter table public.grade_levels        enable row level security;
alter table public.academic_terms      enable row level security;
alter table public.school_settings     enable row level security;
alter table public.enrollments         enable row level security;
alter table public.section_assignments enable row level security;
alter table public.enrollment_versions enable row level security;

-- lookups: read within school; admin manage
create policy gl_read  on public.grade_levels for select using (school_id = current_school_id() or is_super_admin());
create policy gl_admin on public.grade_levels for all using (my_role() in ('school_admin','branch_admin') and school_id = current_school_id()) with check (my_role() in ('school_admin','branch_admin') and school_id = current_school_id());
create policy gl_super on public.grade_levels for all using (is_super_admin()) with check (is_super_admin());

create policy at_read  on public.academic_terms for select using (school_id = current_school_id() or is_super_admin());
create policy at_admin on public.academic_terms for all using (my_role() = 'school_admin' and school_id = current_school_id()) with check (my_role() = 'school_admin' and school_id = current_school_id());
create policy at_super on public.academic_terms for all using (is_super_admin()) with check (is_super_admin());

create policy ss_read  on public.school_settings for select using (school_id = current_school_id() or is_super_admin());
create policy ss_admin on public.school_settings for all using (my_role() in ('school_admin') and school_id = current_school_id()) with check (my_role() in ('school_admin') and school_id = current_school_id());
create policy ss_super on public.school_settings for all using (is_super_admin()) with check (is_super_admin());

-- enrollments
create policy enr_super on public.enrollments for all using (is_super_admin()) with check (is_super_admin());
create policy enr_school_admin on public.enrollments for all
  using (my_role() = 'school_admin' and school_id = current_school_id())
  with check (my_role() = 'school_admin' and school_id = current_school_id());
create policy enr_branch_admin on public.enrollments for all
  using (my_role() = 'branch_admin' and school_id = current_school_id() and branch_id = my_branch_id())
  with check (my_role() = 'branch_admin' and school_id = current_school_id() and branch_id = my_branch_id());
create policy enr_teacher_read on public.enrollments for select
  using (my_role() = 'teacher' and fn_teaches_student(student_id));
create policy enr_student_read on public.enrollments for select
  using (student_id in (select id from public.students where profile_id = auth.uid()));
create policy enr_parent_read on public.enrollments for select
  using (student_id in (select id from public.students where parent_id = auth.uid()));

-- section_assignments: mirror enrollments' visibility; append-only for clients
create policy sa_super on public.section_assignments for select using (is_super_admin());
create policy sa_read on public.section_assignments for select
  using (enrollment_id in (select id from public.enrollments));  -- RLS on enrollments already filters
create policy sa_admin_write on public.section_assignments for insert
  with check (my_role() in ('school_admin','branch_admin') and school_id = current_school_id());
revoke update, delete on public.section_assignments from authenticated, anon;

create policy ev_read on public.enrollment_versions for select
  using (enrollment_id in (select id from public.enrollments));
revoke update, delete on public.enrollment_versions from authenticated, anon;

-- audit
create trigger audit_enrollments after insert or update or delete on public.enrollments
  for each row execute function audit.log_change();
create trigger audit_section_assignments after insert or update or delete on public.section_assignments
  for each row execute function audit.log_change();

-- enforce_row_tenant on the new school_id tables
create trigger trg_enforce_row_tenant before insert on public.enrollments        for each row execute function public.enforce_row_tenant();
create trigger trg_enforce_row_tenant before insert on public.section_assignments for each row execute function public.enforce_row_tenant();
create trigger trg_enforce_row_tenant before insert on public.grade_levels        for each row execute function public.enforce_row_tenant();
create trigger trg_enforce_row_tenant before insert on public.academic_terms      for each row execute function public.enforce_row_tenant();

-- ------------------------------------------------------------
-- 4. Placement-freeze: once state='active', placement columns are immutable.
-- ------------------------------------------------------------
create or replace function public.trg_enrollment_freeze() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if old.state in ('active','completed','transferred_out') then
    if new.academic_year_id is distinct from old.academic_year_id
    or new.branch_id        is distinct from old.branch_id
    or new.program_id       is distinct from old.program_id
    or new.grade_level_id   is distinct from old.grade_level_id
    or new.class_id         is distinct from old.class_id then
      raise exception 'لا يمكن تعديل بيانات التسكين لتسجيل مُفعّل — استخدم دالة تصحيح التسكين'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger enrollment_freeze before update on public.enrollments
  for each row execute function public.trg_enrollment_freeze();

-- ------------------------------------------------------------
-- 5. Bidirectional mirror between students.section_id and
--    section_assignments (open row = current section). Recursion is
--    prevented with pg_trigger_depth().
-- ------------------------------------------------------------

-- 5a. a direct UPDATE of students.section_id -> a section_assignments transition
create or replace function public.trg_students_section_mirror() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_enr uuid;
begin
  if new.section_id is not distinct from old.section_id then return new; end if;
  if pg_trigger_depth() > 1 then return new; end if;   -- cascaded from 5b, nothing to do

  select id into v_enr from public.enrollments
   where student_id = new.id and state = 'active'
   order by enrolled_on desc limit 1;
  if v_enr is null then return new; end if;   -- no active enrollment yet (draft/none)

  update public.section_assignments
     set to_date = current_date
   where enrollment_id = v_enr and to_date is null
     and section_id is distinct from new.section_id;

  if new.section_id is not null then
    insert into public.section_assignments (school_id, enrollment_id, section_id, from_date, assigned_by, reason)
    values (new.school_id, v_enr, new.section_id, current_date, auth.uid(), 'mirror from students.section_id');
  end if;
  return new;
end $$;
create trigger students_section_mirror before update of section_id on public.students
  for each row execute function public.trg_students_section_mirror();

-- 5b. a new open section_assignments row -> students.section_id follows (if active enr)
create or replace function public.trg_section_assignment_mirror() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_student uuid; v_active boolean;
begin
  if new.to_date is not null then return new; end if;      -- only "current" rows drive the mirror
  if pg_trigger_depth() > 1 then return new; end if;       -- cascaded from 5a

  select e.student_id, (e.state = 'active') into v_student, v_active
  from public.enrollments e where e.id = new.enrollment_id;
  if v_student is null or not v_active then return new; end if;

  update public.students set section_id = new.section_id
   where id = v_student and section_id is distinct from new.section_id;
  return new;
end $$;
create trigger section_assignment_mirror after insert on public.section_assignments
  for each row execute function public.trg_section_assignment_mirror();

-- ------------------------------------------------------------
-- 6. EnrollmentSnapshot — "where is student X right now" (read model)
-- ------------------------------------------------------------
create or replace view public.enrollment_snapshot as
select
  e.student_id,
  e.id            as enrollment_id,
  e.school_id,
  e.academic_year_id,
  e.branch_id,
  e.grade_level_id,
  e.class_id,
  e.state,
  sa.section_id,
  sa.from_date    as section_since
from public.enrollments e
left join lateral (
  select section_id, from_date
  from public.section_assignments s
  where s.enrollment_id = e.id and s.to_date is null
  order by from_date desc limit 1
) sa on true
where e.state = 'active';

-- ------------------------------------------------------------
-- 7. RPCs
-- ------------------------------------------------------------
create or replace function public.create_enrollment(
  p_student uuid, p_academic_year uuid, p_class uuid default null,
  p_section uuid default null, p_grade_level uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_school uuid; v_branch uuid; v_id uuid;
begin
  if not (is_super_admin() or (my_role() in ('school_admin','branch_admin'))) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  select school_id, branch_id into v_school, v_branch from public.students where id = p_student;
  if v_school is null then raise exception 'الطالب غير موجود' using errcode='42501'; end if;
  if not is_super_admin() and v_school is distinct from current_school_id() then
    raise exception 'الطالب خارج مدرستك' using errcode='42501';
  end if;
  if p_class is not null then
    select branch_id into v_branch from public.classes where id = p_class;
  end if;

  insert into public.enrollments (school_id, student_id, academic_year_id, branch_id, class_id, grade_level_id, state, created_by)
  values (v_school, p_student, p_academic_year, v_branch, p_class, p_grade_level, 'draft', auth.uid())
  returning id into v_id;

  if p_section is not null then
    insert into public.section_assignments (school_id, enrollment_id, section_id, assigned_by, reason)
    values (v_school, v_id, p_section, auth.uid(), 'initial');
  end if;
  return v_id;
end $$;
revoke execute on function public.create_enrollment(uuid,uuid,uuid,uuid,uuid) from public;
grant  execute on function public.create_enrollment(uuid,uuid,uuid,uuid,uuid) to authenticated;

create or replace function public.activate_enrollment(p_enrollment uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v public.enrollments;
begin
  select * into v from public.enrollments where id = p_enrollment;
  if not found then raise exception 'التسجيل غير موجود' using errcode='42501'; end if;
  if not is_super_admin() and v.school_id is distinct from current_school_id() then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  if v.state <> 'draft' then return; end if;

  -- only one active enrollment per student
  update public.enrollments set state='completed', result='retained', ended_on=current_date
   where student_id = v.student_id and state='active' and id <> p_enrollment;

  update public.enrollments set state='active', updated_by=auth.uid() where id = p_enrollment;

  -- sync the mirror: the open section_assignment (if any) drives students.section_id
  update public.students s set section_id = (
    select section_id from public.section_assignments
     where enrollment_id = p_enrollment and to_date is null order by from_date desc limit 1)
   where s.id = v.student_id;
end $$;
revoke execute on function public.activate_enrollment(uuid) from public;
grant  execute on function public.activate_enrollment(uuid) to authenticated;

create or replace function public.assign_section(p_enrollment uuid, p_section uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v public.enrollments;
begin
  select * into v from public.enrollments where id = p_enrollment;
  if not found then raise exception 'التسجيل غير موجود' using errcode='42501'; end if;
  if not (is_super_admin() or (my_role() in ('school_admin','branch_admin') and v.school_id = current_school_id())
          or (my_role()='teacher' and fn_teaches_student(v.student_id))) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;

  update public.section_assignments set to_date = current_date
   where enrollment_id = p_enrollment and to_date is null and section_id is distinct from p_section;

  if p_section is not null and not exists (
     select 1 from public.section_assignments where enrollment_id = p_enrollment and to_date is null and section_id = p_section) then
    insert into public.section_assignments (school_id, enrollment_id, section_id, assigned_by, reason)
    values (v.school_id, p_enrollment, p_section, auth.uid(), coalesce(p_reason,'reassignment'));
  end if;
end $$;
revoke execute on function public.assign_section(uuid,uuid,text) from public;
grant  execute on function public.assign_section(uuid,uuid,text) to authenticated;

create or replace function public.withdraw_student(p_student uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_school uuid;
begin
  select school_id into v_school from public.students where id = p_student;
  if not (is_super_admin() or (my_role() in ('school_admin','branch_admin') and v_school = current_school_id())) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  update public.enrollments
     set state='withdrawn', result='withdrawn', ended_on=current_date, end_reason=p_reason, updated_by=auth.uid()
   where student_id = p_student and state='active';
  update public.students set is_active=false where id = p_student;
end $$;
revoke execute on function public.withdraw_student(uuid,text) from public;
grant  execute on function public.withdraw_student(uuid,text) to authenticated;

create or replace function public.correct_enrollment_placement(
  p_enrollment uuid, p_class uuid, p_grade_level uuid, p_branch uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare v public.enrollments;
begin
  select * into v from public.enrollments where id = p_enrollment;
  if not found then raise exception 'التسجيل غير موجود' using errcode='42501'; end if;
  if not (is_super_admin() or (my_role()='school_admin' and v.school_id = current_school_id())) then
    raise exception 'غير مصرح — تصحيح التسكين يتطلب صلاحية مدير المدرسة' using errcode='42501';
  end if;
  if v.state = 'completed' then raise exception 'لا يمكن تصحيح تسجيل مكتمل' using errcode='42501'; end if;

  insert into public.enrollment_versions (enrollment_id, version, snapshot, changed_by, reason)
  values (p_enrollment, v.version, to_jsonb(v), auth.uid(), p_reason);

  -- freeze trigger blocks a plain UPDATE for 'active'; do it as the definer
  -- by temporarily disabling via session_replication_role is unsafe — instead
  -- the freeze trigger allows the change when it comes through here because
  -- we bump version and it is the sanctioned path. Implement by dropping the
  -- guard for this statement: use a session flag the trigger checks.
  perform set_config('hamura.enrollment_correcting','1', true);
  update public.enrollments
     set class_id = p_class, grade_level_id = p_grade_level, branch_id = p_branch,
         version = version + 1, updated_by = auth.uid()
   where id = p_enrollment;
  perform set_config('hamura.enrollment_correcting','0', true);
end $$;
revoke execute on function public.correct_enrollment_placement(uuid,uuid,uuid,uuid,text) from public;
grant  execute on function public.correct_enrollment_placement(uuid,uuid,uuid,uuid,text) to authenticated;

-- make the freeze trigger honour the sanctioned correction path
create or replace function public.trg_enrollment_freeze() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if coalesce(current_setting('hamura.enrollment_correcting', true), '0') = '1' then
    return new;
  end if;
  if old.state in ('active','completed','transferred_out') then
    if new.academic_year_id is distinct from old.academic_year_id
    or new.branch_id        is distinct from old.branch_id
    or new.program_id       is distinct from old.program_id
    or new.grade_level_id   is distinct from old.grade_level_id
    or new.class_id         is distinct from old.class_id then
      raise exception 'لا يمكن تعديل بيانات التسكين لتسجيل مُفعّل — استخدم correct_enrollment_placement()'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- ------------------------------------------------------------
-- 8. BACKFILL — one active enrollment per active student for the
--    school's current academic year. Runs as postgres (auth.uid() NULL)
--    so enforce_row_tenant + freeze are inert here.
-- ------------------------------------------------------------
do $$
declare r record; v_enr uuid; v_year uuid; v_grade uuid;
begin
  for r in
    select st.id as student_id, st.school_id, st.branch_id, st.section_id, st.enrolled_at,
           sec.class_id, c.grade_level, c.branch_id as class_branch
    from public.students st
    left join public.sections sec on sec.id = st.section_id
    left join public.classes  c   on c.id = sec.class_id
    where st.is_active
      and not exists (select 1 from public.enrollments e where e.student_id = st.id)
  loop
    select id into v_year from public.academic_years where school_id = r.school_id and is_current limit 1;
    if v_year is null then continue; end if;   -- should not happen after step 0
    select id into v_grade from public.grade_levels where school_id = r.school_id and ordinal = r.grade_level;

    insert into public.enrollments
      (school_id, student_id, academic_year_id, branch_id, class_id, grade_level_id, state, enrolled_on)
    values
      (r.school_id, r.student_id, v_year,
       coalesce(r.class_branch, r.branch_id),
       r.class_id, v_grade,
       case when r.section_id is not null then 'active' else 'draft' end,
       coalesce(r.enrolled_at, current_date))
    returning id into v_enr;

    if r.section_id is not null then
      insert into public.section_assignments (school_id, enrollment_id, section_id, from_date)
      values (r.school_id, v_enr, r.section_id, coalesce(r.enrolled_at, current_date));
    end if;
  end loop;
end $$;

commit;
