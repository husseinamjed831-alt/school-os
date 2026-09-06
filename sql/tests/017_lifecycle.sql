-- ============================================================
-- School OS — 017 record-lifecycle regression. Run AFTER 017.
-- Non-destructive (BEGIN ... ROLLBACK). Verified live 2026-09-06.
-- Actor: a1000000-0000-0000-0000-0000000000a1 (school_admin+owner, test-school-a)
-- ============================================================
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
  do $$
  declare stu uuid; p1 public.payments; p2 public.payments; k uuid := gen_random_uuid();
          att uuid; rev uuid;
          r_idem text; r_pupd text; r_pdel text; r_rev text; r_grade text; r_sdel text; r_adel text;
  begin
    select id into stu from public.students where school_id='a1000000-0000-0000-0000-000000000001' limit 1;

    -- T-PAY-IDEMPOTENT-1
    select * into p1 from public.record_payment(stu,100,'cash','t',k);
    select * into p2 from public.record_payment(stu,100,'cash','t',k);
    r_idem := case when p1.id=p2.id then 'PASS' else 'FAIL' end;

    -- payments immutable
    begin update public.payments set amount=1 where id=p1.id; r_pupd:='FAIL';
      exception when others then r_pupd:='PASS'; end;
    begin delete from public.payments where id=p1.id; r_pdel:='FAIL';
      exception when others then r_pdel:='PASS'; end;

    -- reversal is a compensating record
    select public.reverse_payment(p1.id,'dup') into rev;
    r_rev := case when rev is not null and (select reversed_by from public.payments where id=p1.id) is not null
                  and exists(select 1 from public.payment_reversals where payment_id=p1.id) then 'PASS' else 'FAIL' end;

    -- legacy grades frozen
    begin insert into public.grades(school_id,student_id,subject_id,exam_type,score,max_score)
          values ('a1000000-0000-0000-0000-000000000001',stu,gen_random_uuid(),'final',1,100); r_grade:='FAIL';
      exception when others then r_grade:='PASS'; end;

    -- soft-delete only
    begin delete from public.students where id=stu; r_sdel:='FAIL';
      exception when others then r_sdel:='PASS'; end;

    -- attendance no hard delete
    insert into public.attendance(school_id,student_id,date,status)
      values ('a1000000-0000-0000-0000-000000000001',stu,current_date,'present') returning id into att;
    begin delete from public.attendance where id=att; r_adel:='FAIL';
      exception when others then r_adel:='PASS'; end;

    drop table if exists _r; create temp table _r(
      pay_idempotent text, pay_immutable_update text, pay_immutable_delete text,
      pay_reversal text, legacy_grades_frozen text, student_soft_delete text, attendance_no_delete text);
    insert into _r values (r_idem,r_pupd,r_pdel,r_rev,r_grade,r_sdel,r_adel);
  end $$;
  select * from _r;
rollback;
