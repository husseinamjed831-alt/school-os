-- ============================================================
-- School OS — 007: deterministic analytics + risk engine (v1)
-- Depends on: 001 (students/attendance), 002 (my_role(), my_school_id(),
--   my_branch_id(), is_super_admin()), 004 (fn_teaches_section(),
--   fn_teaches_student()), 005 (assessments/assessment_types/
--   assessment_scores — the whole grade-analytics half of this file)
--
-- No ML, no external calls — pure SQL aggregation so results are
-- reproducible and explainable. This is the layer an AI feature would
-- read from later; it does not depend on any AI provider.
-- ============================================================

-- ---------- Security hardening for RPC-exposed functions ----------
-- security definer functions are PUBLIC-executable by default in Postgres.
-- Anonymous (unauthenticated) callers must never reach these. Tighten the
-- helper functions from earlier migrations too, since this is the first
-- point where anything gets called as an RPC from the client.
revoke execute on function my_role() from public;
revoke execute on function my_school_id() from public;
revoke execute on function my_branch_id() from public;
revoke execute on function is_super_admin() from public;
revoke execute on function fn_teaches_section(uuid) from public;
revoke execute on function fn_teaches_student(uuid) from public;
grant execute on function my_role() to authenticated;
grant execute on function my_school_id() to authenticated;
grant execute on function my_branch_id() to authenticated;
grant execute on function is_super_admin() to authenticated;
grant execute on function fn_teaches_section(uuid) to authenticated;
grant execute on function fn_teaches_student(uuid) to authenticated;

-- ---------- Access-check helpers ----------
create or replace function fn_can_access_student(p_student_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from students s
    where s.id = p_student_id
    and (
      is_super_admin()
      or (my_role() = 'school_admin' and s.school_id = my_school_id())
      or (my_role() = 'branch_admin' and s.branch_id = my_branch_id())
      or (my_role() = 'teacher' and fn_teaches_student(s.id))
      or (my_role() = 'student' and s.profile_id = auth.uid())
      or (my_role() = 'parent' and s.parent_id = auth.uid())
    )
  )
$$;

create or replace function fn_can_access_section(p_section_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from sections sec
    where sec.id = p_section_id
    and (
      is_super_admin()
      or (my_role() = 'school_admin' and sec.school_id = my_school_id())
      or (my_role() = 'branch_admin' and sec.school_id = my_school_id()
          and sec.class_id in (select id from classes where branch_id = my_branch_id()))
      or (my_role() = 'teacher' and fn_teaches_section(sec.id))
    )
  )
$$;

-- Risk scores are staff-only decision-support — not surfaced to the
-- student or parent directly, to avoid a raw unexplained number reading
-- as a clinical or final judgment. Staff interpret it with context.
create or replace function fn_can_view_risk_score(p_student_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from students s
    where s.id = p_student_id
    and (
      is_super_admin()
      or (my_role() = 'school_admin' and s.school_id = my_school_id())
      or (my_role() = 'branch_admin' and s.branch_id = my_branch_id())
      or (my_role() = 'teacher' and fn_teaches_student(s.id))
    )
  )
$$;

-- ---------- Attendance analytics ----------
create or replace function fn_student_attendance_rate(p_student_id uuid, p_start date default null, p_end date default null)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_rate numeric;
begin
  if not fn_can_access_student(p_student_id) then
    raise exception 'غير مصرح بالوصول لبيانات هذا الطالب' using errcode = '42501';
  end if;

  select case when count(*) = 0 then null
    else round(100.0 * count(*) filter (where status in ('present','late')) / count(*), 1)
  end into v_rate
  from attendance
  where student_id = p_student_id
    and (p_start is null or date >= p_start)
    and (p_end is null or date <= p_end);

  return v_rate;
end;
$$;

create or replace function fn_section_attendance_rate(p_section_id uuid, p_date date default current_date)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_rate numeric;
begin
  if not fn_can_access_section(p_section_id) then
    raise exception 'غير مصرح بالوصول لبيانات هذه الشعبة' using errcode = '42501';
  end if;

  select case when count(*) = 0 then null
    else round(100.0 * count(*) filter (where a.status in ('present','late')) / count(*), 1)
  end into v_rate
  from attendance a
  join students st on st.id = a.student_id
  where st.section_id = p_section_id and a.date = p_date;

  return v_rate;
end;
$$;

-- ---------- Grade analytics ----------
create or replace function fn_student_missing_assignments_count(p_student_id uuid) returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_can_access_student(p_student_id) then
    raise exception 'غير مصرح بالوصول لبيانات هذا الطالب' using errcode = '42501';
  end if;
  return (select count(*)::int from assessment_scores where student_id = p_student_id and is_missing = true);
end;
$$;

create or replace function fn_student_grade_summary(p_student_id uuid)
returns table(subject_id uuid, subject_name text, weighted_percent numeric, assessments_count int, missing_count int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_can_access_student(p_student_id) then
    raise exception 'غير مصرح بالوصول لبيانات هذا الطالب' using errcode = '42501';
  end if;

  return query
  with scored as (
    select
      a.subject_id,
      at.weight_percent,
      sc.score,
      a.max_score,
      sc.is_missing
    from assessment_scores sc
    join assessments a on a.id = sc.assessment_id
    join assessment_types at on at.id = a.assessment_type_id
    where sc.student_id = p_student_id
  ),
  per_subject as (
    select
      scored.subject_id,
      sum(scored.weight_percent) filter (where scored.score is not null) as total_weight,
      sum((scored.score / nullif(scored.max_score, 0)) * scored.weight_percent) filter (where scored.score is not null) as earned_weight,
      count(*) as assessments_count,
      count(*) filter (where scored.is_missing) as missing_count
    from scored
    group by scored.subject_id
  )
  select
    ps.subject_id,
    sub.name,
    case when ps.total_weight > 0 then round(100.0 * ps.earned_weight / ps.total_weight, 1) else null end,
    ps.assessments_count::int,
    ps.missing_count::int
  from per_subject ps
  join subjects sub on sub.id = ps.subject_id;
end;
$$;

create or replace function fn_section_grade_summary(p_section_id uuid, p_subject_id uuid)
returns table(student_id uuid, student_name text, weighted_percent numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_can_access_section(p_section_id) then
    raise exception 'غير مصرح بالوصول لبيانات هذه الشعبة' using errcode = '42501';
  end if;

  return query
  with scored as (
    select
      sc.student_id,
      at.weight_percent,
      sc.score,
      a.max_score
    from assessment_scores sc
    join assessments a on a.id = sc.assessment_id
    join assessment_types at on at.id = a.assessment_type_id
    join students st on st.id = sc.student_id
    where st.section_id = p_section_id and a.subject_id = p_subject_id
  ),
  per_student as (
    select
      scored.student_id,
      sum(scored.weight_percent) filter (where scored.score is not null) as total_weight,
      sum((scored.score / nullif(scored.max_score, 0)) * scored.weight_percent) filter (where scored.score is not null) as earned_weight
    from scored
    group by scored.student_id
  )
  select
    st.id,
    st.full_name,
    case when ps.total_weight > 0 then round(100.0 * ps.earned_weight / ps.total_weight, 1) else null end
  from students st
  left join per_student ps on ps.student_id = st.id
  where st.section_id = p_section_id and st.is_active = true
  order by st.full_name;
end;
$$;

-- ---------- Trend detection (used by the risk engine) ----------
create or replace function fn_subject_is_declining(p_student_id uuid, p_subject_id uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_recent numeric;
  v_prior numeric;
begin
  if not fn_can_access_student(p_student_id) then
    raise exception 'غير مصرح بالوصول لبيانات هذا الطالب' using errcode = '42501';
  end if;

  with ordered as (
    select
      (sc.score / nullif(a.max_score, 0)) * 100 as pct,
      row_number() over (order by a.assessment_date desc) as rn
    from assessment_scores sc
    join assessments a on a.id = sc.assessment_id
    where sc.student_id = p_student_id and a.subject_id = p_subject_id and sc.score is not null
  )
  select avg(pct) filter (where rn <= 2), avg(pct) filter (where rn between 3 and 5)
  into v_recent, v_prior
  from ordered;

  return v_recent is not null and v_prior is not null and v_recent < v_prior - 10;
end;
$$;

-- ---------- Risk engine v1 (rule-based, explainable, not ML) ----------
-- IMPORTANT: this is a decision-support indicator only. It does not
-- diagnose, and it is never shown to the student or parent (see
-- fn_can_view_risk_score) — only staff, with context, see it.
create or replace function fn_student_risk_score(p_student_id uuid)
returns table(risk_score int, risk_level text, risk_factors jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  v_attendance numeric;
  v_missing int;
  v_avg_grade numeric;
  v_score int := 0;
  v_factors jsonb := '[]'::jsonb;
  v_subject record;
  v_declining_subjects int := 0;
begin
  if not fn_can_view_risk_score(p_student_id) then
    raise exception 'غير مصرح بالوصول لمؤشر المخاطر لهذا الطالب' using errcode = '42501';
  end if;

  -- `current_date - interval` yields a timestamp, not a date, and this
  -- function's signature is (uuid, date, date) — `date - integer` stays a
  -- date and avoids depending on Postgres's implicit-cast resolution.
  select fn_student_attendance_rate(p_student_id, current_date - 90, current_date) into v_attendance;
  select fn_student_missing_assignments_count(p_student_id) into v_missing;
  select round(avg(weighted_percent), 1) into v_avg_grade
  from fn_student_grade_summary(p_student_id)
  where weighted_percent is not null;

  if v_attendance is not null then
    if v_attendance < 75 then
      v_score := v_score + 40;
      v_factors := v_factors || jsonb_build_array('نسبة الحضور منخفضة جداً (' || v_attendance || '%)');
    elsif v_attendance < 90 then
      v_score := v_score + 20;
      v_factors := v_factors || jsonb_build_array('نسبة الحضور أقل من المطلوب (' || v_attendance || '%)');
    end if;
  end if;

  if v_avg_grade is not null then
    if v_avg_grade < 60 then
      v_score := v_score + 30;
      v_factors := v_factors || jsonb_build_array('المعدل العام منخفض (' || v_avg_grade || '%)');
    elsif v_avg_grade < 70 then
      v_score := v_score + 15;
      v_factors := v_factors || jsonb_build_array('المعدل العام دون المستوى المطلوب (' || v_avg_grade || '%)');
    end if;
  end if;

  if v_missing > 0 then
    v_score := v_score + least(v_missing * 5, 25);
    v_factors := v_factors || jsonb_build_array(v_missing || ' من التقييمات لم تُسلَّم');
  end if;

  for v_subject in
    select distinct a.subject_id
    from assessment_scores sc
    join assessments a on a.id = sc.assessment_id
    where sc.student_id = p_student_id and sc.score is not null
  loop
    if fn_subject_is_declining(p_student_id, v_subject.subject_id) then
      v_declining_subjects := v_declining_subjects + 1;
    end if;
  end loop;

  if v_declining_subjects > 0 then
    v_score := v_score + least(v_declining_subjects * 10, 20);
    v_factors := v_factors || jsonb_build_array(v_declining_subjects || ' مادة يتراجع فيها أداء الطالب مؤخراً');
  end if;

  v_score := least(v_score, 100);

  return query select
    v_score,
    case when v_score >= 70 then 'high' when v_score >= 40 then 'medium' else 'low' end,
    v_factors;
end;
$$;

-- ---------- Grants (deny-by-default, then allow authenticated) ----------
revoke execute on function fn_can_access_student(uuid) from public;
revoke execute on function fn_can_access_section(uuid) from public;
revoke execute on function fn_can_view_risk_score(uuid) from public;
revoke execute on function fn_student_attendance_rate(uuid, date, date) from public;
revoke execute on function fn_section_attendance_rate(uuid, date) from public;
revoke execute on function fn_student_missing_assignments_count(uuid) from public;
revoke execute on function fn_student_grade_summary(uuid) from public;
revoke execute on function fn_section_grade_summary(uuid, uuid) from public;
revoke execute on function fn_subject_is_declining(uuid, uuid) from public;
revoke execute on function fn_student_risk_score(uuid) from public;

grant execute on function fn_can_access_student(uuid) to authenticated;
grant execute on function fn_can_access_section(uuid) to authenticated;
grant execute on function fn_can_view_risk_score(uuid) to authenticated;
grant execute on function fn_student_attendance_rate(uuid, date, date) to authenticated;
grant execute on function fn_section_attendance_rate(uuid, date) to authenticated;
grant execute on function fn_student_missing_assignments_count(uuid) to authenticated;
grant execute on function fn_student_grade_summary(uuid) to authenticated;
grant execute on function fn_section_grade_summary(uuid, uuid) to authenticated;
grant execute on function fn_subject_is_declining(uuid, uuid) to authenticated;
grant execute on function fn_student_risk_score(uuid) to authenticated;
