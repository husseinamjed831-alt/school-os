-- ============================================================
-- School OS — 017 ROLLBACK. Restores default grants + drops lifecycle
-- objects. payments DATA (incl. backfilled number/idempotency_key) is
-- kept; the columns are dropped.
-- ============================================================
begin;

drop function if exists public.correct_score(uuid,numeric,text);
drop function if exists public.correct_attendance(uuid,text,text);
drop function if exists public.reverse_payment(uuid,text);
drop function if exists public.record_payment(uuid,numeric,text,text,uuid,date);

drop trigger if exists scores_lifecycle_trg on public.assessment_scores;
drop function if exists public.scores_lifecycle();
drop trigger if exists attendance_lifecycle_trg on public.attendance;
drop function if exists public.attendance_lifecycle();
drop trigger if exists payments_immutable_trg on public.payments;
drop function if exists public.payments_immutable();

drop table if exists public.payment_reversals;
drop table if exists public.payment_seq;

alter table public.assessment_scores drop column if exists state;
alter table public.assessment_scores drop column if exists superseded_by;
alter table public.attendance drop column if exists state;
alter table public.attendance drop column if exists superseded_by;
alter table public.attendance drop column if exists corrected_from;
alter table public.payments drop column if exists idempotency_key;
alter table public.payments drop column if exists number;
alter table public.payments drop column if exists reversed_by;
alter table public.classes  drop column if exists archived_at;
alter table public.sections drop column if exists archived_at;

grant update, delete on public.payments to authenticated;
grant delete on public.attendance to authenticated;
grant delete on public.assessment_scores to authenticated;
grant insert, update, delete on public.grades to authenticated;
grant delete on public.students to authenticated;
grant delete on public.classes to authenticated;
grant delete on public.sections to authenticated;

commit;
