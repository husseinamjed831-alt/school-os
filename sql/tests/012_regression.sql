-- ============================================================
-- School OS — 012 regression tests. Run AFTER applying 012.
-- Non-destructive: every write is inside BEGIN ... ROLLBACK.
-- Set the two :params from:
--   select id, role, school_id from profiles where role='teacher' limit 1;   -- :teacher_uid
--   select id, role, school_id from profiles where role='school_admin' limit 1; -- :admin_uid
--   select id from schools limit 5;   -- pick :other_school <> the admin's school
-- Every check RAISEs 'FAIL ...' if the fix regressed, else NOTICEs 'PASS ...'.
-- ============================================================

-- ---- T-1  D1: self role escalation is blocked --------------
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":":teacher_uid","role":"authenticated"}';
  do $$
  begin
    begin
      update public.profiles set role = 'super_admin' where id = ':teacher_uid';
      raise exception 'FAIL T-1a: teacher escalated own role to super_admin';
    exception
      when sqlstate '42501' then raise notice 'PASS T-1a: self role change blocked';
      when others then raise notice 'PASS T-1a (blocked, %):%', SQLSTATE, SQLERRM;
    end;
    begin
      update public.profiles set school_id = gen_random_uuid() where id = ':teacher_uid';
      raise exception 'FAIL T-1b: teacher moved own profile to another school';
    exception
      when sqlstate '42501' then raise notice 'PASS T-1b: self school_id change blocked';
      when others then raise notice 'PASS T-1b (blocked, %)', SQLSTATE;
    end;
    -- sanity: a benign self-update still works
    begin
      update public.profiles set full_name = full_name where id = ':teacher_uid';
      raise notice 'PASS T-1c: benign self-update (full_name) still allowed';
    exception when others then
      raise exception 'FAIL T-1c: benign self-update now blocked: % %', SQLSTATE, SQLERRM;
    end;
  end;
  $$;
rollback;

-- ---- T-2  B2: tenant spoof on INSERT is neutralised --------
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":":admin_uid","role":"authenticated"}';
  do $$
  declare v_id uuid; v_school uuid; v_mine uuid;
  begin
    select school_id into v_mine from public.profiles where id = ':admin_uid';

    insert into public.students (school_id, full_name)
    values (':other_school', 'T-2 spoof')
    returning id, school_id into v_id, v_school;

    if v_school = ':other_school'::uuid then
      raise exception 'FAIL T-2: student landed in foreign school %', v_school;
    elsif v_school = v_mine then
      raise notice 'PASS T-2: enforce_row_tenant rewrote school_id to caller''s (%).', v_school;
    else
      raise exception 'FAIL T-2: unexpected school_id %', v_school;
    end if;
  exception
    when sqlstate '42501' then raise notice 'PASS T-2: foreign-tenant insert rejected';
  end;
  $$;
rollback;

-- ---- T-3  P0-4: catalog coverage of USING / WITH CHECK -----
-- Not an assertion — prints the current state. Expect 'ok' for the
-- 002/004/005/006/009 policy set (they already carry symmetric checks);
-- anything else is a Phase-2 target, not a Phase-1 regression.
select verdict, count(*)
from (
  select case
    when p.cmd in ('ALL','UPDATE','INSERT') and p.with_check is null then 'MISSING_WITH_CHECK'
    when p.cmd in ('ALL','UPDATE','INSERT')
     and coalesce(p.with_check,'') !~* 'my_school_id|is_super_admin|current_school_id|auth.uid' then 'WITH_CHECK_NO_TENANT'
    else 'ok'
  end as verdict
  from pg_policies p
  join information_schema.columns c
    on c.table_schema=p.schemaname and c.table_name=p.tablename and c.column_name='school_id'
  where p.schemaname='public'
) z
group by verdict order by verdict;

-- ---- T-4  A1: phone collisions must be zero before the index
select
  (select count(*) from (
     select public.normalize_phone(phone) np from public.profiles
     where phone is not null and public.normalize_phone(phone) <> ''
     group by public.normalize_phone(phone) having count(distinct school_id) > 1) a) as cross_school_dupe_phones,
  (select count(*) from (
     select school_id, public.normalize_phone(phone) np from public.profiles
     where phone is not null and public.normalize_phone(phone) <> ''
     group by school_id, public.normalize_phone(phone) having count(*) > 1) b) as in_school_dupe_phones;

-- ---- T-5  smoke: normalize_phone parity with the JS impl -----------
--   JS: value.replace(/[\s-]/g,"").replace(/^\+?00?/,"")
--   NOTE: a lone leading '+' is NOT stripped (the regex needs a '0'
--   after the optional '+'), so '+9647...' keeps its '+'. This is a
--   pre-existing quirk: a user who stored '+964...' will not match one
--   who stored '0...' — same-format login is required within a school.
do $$
begin
  if public.normalize_phone('07730018178')   <> '7730018178'     then raise exception 'FAIL T-5a: %', public.normalize_phone('07730018178'); end if;
  if public.normalize_phone('077 3001-8178') <> '7730018178'     then raise exception 'FAIL T-5b: %', public.normalize_phone('077 3001-8178'); end if;
  if public.normalize_phone('+9647730018178')<> '+9647730018178' then raise exception 'FAIL T-5c: %', public.normalize_phone('+9647730018178'); end if;
  if public.normalize_phone('00964773')      <> '964773'         then raise exception 'FAIL T-5d: %', public.normalize_phone('00964773'); end if;
  raise notice 'PASS T-5: normalize_phone matches the Edge Function normalization';
end;
$$;
