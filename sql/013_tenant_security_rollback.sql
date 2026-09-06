-- ============================================================
-- School OS — 013 ROLLBACK. Restores the pre-013 teacher_read_students
-- policy (school-wide) and drops the new helpers. enforce_row_tenant()
-- is restored to its 012 body (my_school_id()).
-- ============================================================
begin;

drop policy if exists teacher_read_students on public.students;
create policy teacher_read_students on public.students
  for select
  using ((my_role() = 'teacher') and (school_id = my_school_id()));

create or replace function public.enforce_row_tenant()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_my_school uuid;
begin
  if auth.uid() is null then return new; end if;
  if coalesce(is_super_admin(), false) then return new; end if;
  v_my_school := my_school_id();
  if v_my_school is null then
    raise exception 'تعذّر تحديد المدرسة لحسابك — لا يمكن إنشاء سجلات بدون سياق مدرسة' using errcode = '42501';
  end if;
  new.school_id := v_my_school;
  return new;
end;
$$;

drop function if exists public.school_is_operational(uuid);
drop function if exists public.current_school_id();

commit;
