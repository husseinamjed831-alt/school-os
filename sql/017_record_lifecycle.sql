-- ============================================================
-- School OS — 017: sensitive-record lifecycles (V1 Phase 5, migration M5)
-- Depends on: 001, 009 (fees/payments), 005 (assessment_scores), 013
--   (current_school_id), 015 (school_settings), 016 (record_audit_event,
--   emit_event).
--
-- attendance & assessment_scores are currently EMPTY (verified) and the
-- legacy `grades` table is unused, so lifecycle columns + locks are added
-- with no compat risk. `payments` (1 row) becomes IMMUTABLE + idempotent;
-- corrections/reversals are compensating records, never edits/deletes.
--
-- Rollback: sql/017_record_lifecycle_rollback.sql  Tests: sql/tests/017_lifecycle.sql
-- ============================================================

begin;

-- ============================================================
-- 1. PAYMENTS — immutable + idempotent + reversible
-- ============================================================
alter table public.payments add column if not exists idempotency_key uuid;
alter table public.payments add column if not exists number          bigint;
alter table public.payments add column if not exists reversed_by     uuid;

-- backfill existing rows
update public.payments p set idempotency_key = gen_random_uuid() where idempotency_key is null;
with ordered as (
  select id, row_number() over (partition by school_id order by created_at, id) rn from public.payments
)
update public.payments p set number = o.rn from ordered o where o.id = p.id and p.number is null;

create unique index if not exists payments_idem_uq on public.payments(school_id, idempotency_key);

create table if not exists public.payment_seq (
  school_id uuid primary key references public.schools(id) on delete cascade,
  next_val  bigint not null default 1
);
insert into public.payment_seq (school_id, next_val)
select school_id, coalesce(max(number),0)+1 from public.payments group by school_id
on conflict (school_id) do nothing;

create table if not exists public.payment_reversals (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  payment_id    uuid not null references public.payments(id) on delete restrict,
  amount        numeric(12,2) not null check (amount > 0),
  reason        text not null,
  approved_by   uuid references public.profiles(id) on delete set null,
  reversed_at   timestamptz not null default now()
);
create index if not exists payment_reversals_school_idx on public.payment_reversals(school_id);
alter table public.payment_reversals enable row level security;
create policy pr_super on public.payment_reversals for all using (is_super_admin()) with check (is_super_admin());
create policy pr_admin on public.payment_reversals for select
  using (school_id = current_school_id() and my_role() in ('school_admin','branch_admin'));
create policy pr_parent on public.payment_reversals for select
  using (payment_id in (select id from public.payments where student_id in (select id from public.students where parent_id = auth.uid())));
revoke update, delete on public.payment_reversals from authenticated, anon;
create trigger audit_payment_reversals after insert or update or delete on public.payment_reversals
  for each row execute function audit.log_change();
create trigger trg_enforce_row_tenant before insert on public.payment_reversals
  for each row execute function public.enforce_row_tenant();

-- immutability: only `reversed_by` may change post-insert (set by reverse_payment)
create or replace function public.payments_immutable() returns trigger
language plpgsql as $$
begin
  if TG_OP = 'DELETE' then
    raise exception 'لا يمكن حذف دفعة — استخدم عكس الدفعة' using errcode = '2F004';
  end if;
  if (new.school_id, new.student_id, new.amount, new.paid_at, new.method, new.note,
      new.recorded_by, new.created_at, new.idempotency_key, new.number)
     is distinct from
     (old.school_id, old.student_id, old.amount, old.paid_at, old.method, old.note,
      old.recorded_by, old.created_at, old.idempotency_key, old.number) then
    raise exception 'الدفعة غير قابلة للتعديل — استخدم عكس الدفعة (reverse_payment)' using errcode = '2F004';
  end if;
  return new;
end $$;
drop trigger if exists payments_immutable_trg on public.payments;
create trigger payments_immutable_trg before update or delete on public.payments
  for each row execute function public.payments_immutable();
revoke update, delete, truncate on public.payments from authenticated, anon;

create or replace function public.record_payment(
  p_student uuid, p_amount numeric, p_method text default 'cash',
  p_note text default null, p_idempotency_key uuid default null,
  p_paid_at date default current_date)
returns public.payments
language plpgsql security definer set search_path = public as $$
declare v_school uuid; v_key uuid := coalesce(p_idempotency_key, gen_random_uuid());
        v_num bigint; v_row public.payments;
begin
  if not (is_super_admin() or (my_role() in ('school_admin','branch_admin','finance_manager','staff'))) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  select school_id into v_school from public.students where id = p_student;
  if v_school is null then raise exception 'الطالب غير موجود' using errcode='42501'; end if;
  if not is_super_admin() and v_school is distinct from current_school_id() then
    raise exception 'الطالب خارج مدرستك' using errcode='42501';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'المبلغ غير صالح' using errcode='22023'; end if;
  if not public.school_is_operational(v_school) then raise exception 'المدرسة موقوفة حالياً' using errcode='42501'; end if;

  -- idempotency: replay returns the original
  select * into v_row from public.payments where school_id = v_school and idempotency_key = v_key;
  if found then return v_row; end if;

  update public.payment_seq set next_val = next_val + 1 where school_id = v_school returning next_val - 1 into v_num;
  if v_num is null then
    insert into public.payment_seq(school_id, next_val) values (v_school, 2) returning next_val - 1 into v_num;
  end if;

  insert into public.payments (school_id, student_id, amount, paid_at, method, note, recorded_by, idempotency_key, number)
  values (v_school, p_student, p_amount, p_paid_at, coalesce(p_method,'cash'), p_note, auth.uid(), v_key, v_num)
  returning * into v_row;

  perform public.record_audit_event('payment.recorded','payment', v_row.id, null, to_jsonb(v_row));
  perform public.emit_event('PaymentReceived','payment', v_row.id,
    jsonb_build_object('student_id',p_student,'amount',p_amount,'number',v_num));
  return v_row;
end $$;
revoke execute on function public.record_payment(uuid,numeric,text,text,uuid,date) from public;
grant  execute on function public.record_payment(uuid,numeric,text,text,uuid,date) to authenticated;

create or replace function public.reverse_payment(p_payment uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_p public.payments; v_id uuid;
begin
  select * into v_p from public.payments where id = p_payment;
  if not found then raise exception 'الدفعة غير موجودة' using errcode='42501'; end if;
  if not (is_super_admin() or (my_role() in ('school_admin','finance_manager') and v_p.school_id = current_school_id())) then
    raise exception 'غير مصرح — عكس الدفعة يتطلب صلاحية مدير/مسؤول مالي' using errcode='42501';
  end if;
  if v_p.reversed_by is not null then raise exception 'الدفعة معكوسة مسبقاً' using errcode='42501'; end if;
  if coalesce(p_reason,'') = '' then raise exception 'سبب العكس مطلوب' using errcode='22023'; end if;

  insert into public.payment_reversals (school_id, payment_id, amount, reason, approved_by)
  values (v_p.school_id, p_payment, v_p.amount, p_reason, auth.uid())
  returning id into v_id;

  update public.payments set reversed_by = auth.uid() where id = p_payment;

  perform public.record_audit_event('payment.reversed','payment', p_payment, to_jsonb(v_p),
    jsonb_build_object('reversal_id',v_id,'reason',p_reason));
  perform public.emit_event('PaymentReversed','payment', p_payment,
    jsonb_build_object('reversal_id',v_id,'amount',v_p.amount));
  return v_id;
end $$;
revoke execute on function public.reverse_payment(uuid,text) from public;
grant  execute on function public.reverse_payment(uuid,text) to authenticated;

-- ============================================================
-- 2. ATTENDANCE — lifecycle + lock after a grace window
-- ============================================================
alter table public.attendance add column if not exists state text not null default 'submitted'
  check (state in ('draft','submitted','superseded'));
alter table public.attendance add column if not exists superseded_by uuid;
alter table public.attendance add column if not exists corrected_from uuid;

create or replace function public.attendance_lifecycle() returns trigger
language plpgsql as $$
declare v_grace int;
begin
  if TG_OP = 'DELETE' then
    raise exception 'لا يمكن حذف سجل حضور — استخدم تصحيح الحضور' using errcode='2F004';
  end if;
  if coalesce(current_setting('hamura.correcting_attendance', true),'0') = '1' then
    return new;
  end if;
  if old.state = 'superseded' then
    -- only the correction path (which sets superseded_by) may touch it
    if new.superseded_by is not null and (
       new.status, new.note, new.state, new.date, new.student_id) is not distinct from
       (old.status, old.note, old.state, old.date, old.student_id) then
      return new;
    end if;
    raise exception 'سجل الحضور مُستبدل ولا يقبل التعديل' using errcode='2F004';
  end if;
  -- lock status changes on old records unless admin
  if new.status is distinct from old.status then
    select attendance_locks_after_days into v_grace from public.school_settings where school_id = old.school_id;
    v_grace := coalesce(v_grace, 3);
    if old.date < current_date - v_grace
       and coalesce(my_role(),'') not in ('school_admin','branch_admin','super_admin')
       and auth.uid() is not null then
      raise exception 'انتهت مهلة تعديل هذا السجل — استخدم طلب تصحيح' using errcode='42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists attendance_lifecycle_trg on public.attendance;
create trigger attendance_lifecycle_trg before update or delete on public.attendance
  for each row execute function public.attendance_lifecycle();
revoke delete, truncate on public.attendance from authenticated, anon;

create or replace function public.correct_attendance(p_id uuid, p_status text, p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_old public.attendance; v_new uuid;
begin
  select * into v_old from public.attendance where id = p_id;
  if not found then raise exception 'السجل غير موجود' using errcode='42501'; end if;
  if not (is_super_admin() or (my_role() in ('school_admin','branch_admin') and v_old.school_id = current_school_id())
          or (my_role()='teacher' and fn_teaches_student(v_old.student_id))) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  if p_status not in ('present','absent','late','excused') then raise exception 'حالة غير صالحة' using errcode='22023'; end if;

  -- the existing unique(student_id,date) means the correction is applied
  -- in place; the immutable audit trail (016) preserves the prior state.
  -- Row-level superseding arrives with attendance_records (post-cutover).
  perform set_config('hamura.correcting_attendance','1', true);
  update public.attendance
     set status = p_status, note = coalesce(p_reason, note),
         recorded_by = auth.uid(), corrected_from = p_id
   where id = p_id;
  perform set_config('hamura.correcting_attendance','0', true);
  v_new := p_id;

  perform public.record_audit_event('attendance.corrected','attendance', p_id,
    to_jsonb(v_old), jsonb_build_object('to_status',p_status,'reason',p_reason,'new_id',v_new));
  perform public.emit_event('AttendanceCorrected','attendance', coalesce(v_new,p_id),
    jsonb_build_object('from',v_old.status,'to',p_status));
  return coalesce(v_new, p_id);
end $$;
revoke execute on function public.correct_attendance(uuid,text,text) from public;
grant  execute on function public.correct_attendance(uuid,text,text) to authenticated;

-- ============================================================
-- 3. ASSESSMENT_SCORES — lifecycle + lock; grades (legacy) frozen
-- ============================================================
alter table public.assessment_scores add column if not exists state text not null default 'published'
  check (state in ('draft','submitted','published','rechecked','superseded'));
alter table public.assessment_scores add column if not exists superseded_by uuid;

create or replace function public.scores_lifecycle() returns trigger
language plpgsql as $$
begin
  if TG_OP = 'DELETE' then
    raise exception 'لا يمكن حذف درجة — استخدم تصحيح الدرجة' using errcode='2F004';
  end if;
  if old.state in ('superseded') then
    raise exception 'الدرجة مُستبدلة ولا تقبل التعديل' using errcode='2F004';
  end if;
  if old.state in ('published','rechecked') and new.score is distinct from old.score
     and coalesce(my_role(),'') not in ('school_admin','branch_admin','super_admin')
     and auth.uid() is not null then
    raise exception 'الدرجة منشورة — استخدم تصحيح الدرجة (correct_score)' using errcode='42501';
  end if;
  return new;
end $$;
drop trigger if exists scores_lifecycle_trg on public.assessment_scores;
create trigger scores_lifecycle_trg before update or delete on public.assessment_scores
  for each row execute function public.scores_lifecycle();
revoke delete, truncate on public.assessment_scores from authenticated, anon;

create or replace function public.correct_score(p_id uuid, p_score numeric, p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_old public.assessment_scores; v_new uuid;
begin
  select * into v_old from public.assessment_scores where id = p_id;
  if not found then raise exception 'الدرجة غير موجودة' using errcode='42501'; end if;
  if not (is_super_admin() or (my_role() in ('school_admin','branch_admin') and v_old.school_id = current_school_id())
          or (my_role()='teacher' and fn_teaches_student(v_old.student_id))) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;

  insert into public.assessment_scores (school_id, assessment_id, student_id, score, is_missing, graded_by, graded_at, state)
  values (v_old.school_id, v_old.assessment_id, v_old.student_id, p_score, false, auth.uid(), now(), 'rechecked')
  on conflict (assessment_id, student_id) do update
     set score = excluded.score, graded_by = excluded.graded_by, graded_at = excluded.graded_at, state = 'rechecked'
  returning id into v_new;

  if v_new <> p_id then
    update public.assessment_scores set state='superseded', superseded_by = v_new where id = p_id;
  end if;

  perform public.record_audit_event('grade.corrected','assessment_score', p_id,
    to_jsonb(v_old), jsonb_build_object('to_score',p_score,'reason',p_reason,'new_id',v_new));
  perform public.emit_event('GradeCorrected','assessment_score', coalesce(v_new,p_id),
    jsonb_build_object('from',v_old.score,'to',p_score));
  return coalesce(v_new, p_id);
end $$;
revoke execute on function public.correct_score(uuid,numeric,text) from public;
grant  execute on function public.correct_score(uuid,numeric,text) to authenticated;

-- legacy grades table: fully frozen (dead since 005)
revoke insert, update, delete, truncate on public.grades from authenticated, anon;

-- ============================================================
-- 4. SOFT-DELETE ONLY for students / classes / sections
-- ============================================================
alter table public.classes  add column if not exists archived_at timestamptz;
alter table public.sections add column if not exists archived_at timestamptz;
revoke delete, truncate on public.students from authenticated, anon;
revoke delete, truncate on public.classes  from authenticated, anon;
revoke delete, truncate on public.sections from authenticated, anon;

commit;
