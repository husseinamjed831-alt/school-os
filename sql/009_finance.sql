-- ============================================================
-- School OS — 009: fees & payments
-- Depends on: 001 (schools/students/academic_years/profiles), 002
--   (my_role(), my_school_id(), my_branch_id()), 003 (audit.log_change()),
--   007 (fn_can_access_student() — reused for the balance function's
--   authorization check)
--
-- No payment gateway integration — out of scope per the original spec.
-- This tracks fees owed and payments recorded by staff (cash/transfer/etc),
-- the same "record what happened" model as attendance/grades.
-- ============================================================

create table fees (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  academic_year_id uuid not null references academic_years(id) on delete cascade,
  grade_level int not null,
  annual_amount numeric(12,2) not null check (annual_amount >= 0),
  currency text not null default 'IQD',
  created_at timestamptz not null default now(),
  unique (school_id, academic_year_id, grade_level)
);
create index fees_school_idx on fees(school_id);

create table payments (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  paid_at date not null default current_date,
  method text not null default 'cash' check (method in ('cash', 'bank_transfer', 'card', 'other')),
  note text,
  recorded_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index payments_school_idx on payments(school_id);
create index payments_student_idx on payments(student_id);

alter table fees enable row level security;
alter table payments enable row level security;

-- ---------- fees: admin-managed reference data, readable school-wide ----------
create policy super_admin_all_fees on fees for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_fees on fees for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy read_own_school_fees on fees for select
  using (school_id = my_school_id());

-- ---------- payments ----------
create policy super_admin_all_payments on payments for all
  using (is_super_admin()) with check (is_super_admin());
create policy school_admin_all_payments on payments for all
  using (my_role() = 'school_admin' and school_id = my_school_id())
  with check (my_role() = 'school_admin' and school_id = my_school_id());
create policy branch_admin_all_payments on payments for all
  using (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  )
  with check (
    my_role() = 'branch_admin' and school_id = my_school_id()
    and student_id in (select id from students where branch_id = my_branch_id())
  );
-- Financial data is deliberately staff-only to read, even for the student
-- themselves — parents are the ones who see/manage payments, matching how
-- tuition is actually handled (the parent pays, not the student). No
-- student-role select policy exists; this is a default-deny, not an
-- oversight.
create policy parent_children_payments on payments for select
  using (student_id in (select id from students where parent_id = auth.uid()));

create trigger audit_payments after insert or update or delete on payments
  for each row execute function audit.log_change();

-- Finance visibility is narrower than fn_can_access_student (which also
-- allows the student and any of their teachers) — payments RLS above only
-- grants staff and parents, no student or teacher policy, so the balance
-- function needs its own matching check rather than the general one.
create or replace function fn_can_view_finance(p_student_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from students s
    where s.id = p_student_id
    and (
      is_super_admin()
      or (my_role() = 'school_admin' and s.school_id = my_school_id())
      or (my_role() = 'branch_admin' and s.branch_id = my_branch_id())
      or (my_role() = 'parent' and s.parent_id = auth.uid())
    )
  )
$$;
revoke execute on function fn_can_view_finance(uuid) from public;
grant execute on function fn_can_view_finance(uuid) to authenticated;

-- ============================================================
-- Balance function: annual fee (by the student's grade level + current
-- academic year) minus total payments recorded. Same access-check pattern
-- as the 007 analytics functions.
-- ============================================================
create or replace function fn_student_balance(p_student_id uuid)
returns table(annual_amount numeric, total_paid numeric, remaining numeric, currency text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school_id uuid;
  v_grade_level int;
begin
  if not fn_can_view_finance(p_student_id) then
    raise exception 'غير مصرح بالوصول للبيانات المالية لهذا الطالب' using errcode = '42501';
  end if;

  select st.school_id, c.grade_level into v_school_id, v_grade_level
  from students st
  left join sections sec on sec.id = st.section_id
  left join classes c on c.id = sec.class_id
  where st.id = p_student_id;

  return query
  with fee as (
    select f.annual_amount, f.currency
    from fees f
    join academic_years ay on ay.id = f.academic_year_id
    where f.school_id = v_school_id and f.grade_level = v_grade_level and ay.is_current = true
    limit 1
  ),
  paid as (
    select coalesce(sum(amount), 0) as total from payments where student_id = p_student_id
  )
  select
    coalesce(fee.annual_amount, 0),
    paid.total,
    coalesce(fee.annual_amount, 0) - paid.total,
    coalesce(fee.currency, 'IQD')
  from paid
  left join fee on true;
end;
$$;

revoke execute on function fn_student_balance(uuid) from public;
grant execute on function fn_student_balance(uuid) to authenticated;
