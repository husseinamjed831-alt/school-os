-- ============================================================
-- School OS — 012: live security fixes (Phase 1 of HAMURA V1)
-- Depends on: 001 (profiles + every tenant table), 002 (my_role(),
--   my_school_id(), my_branch_id(), is_super_admin()).
-- Does NOT edit 001–011. Purely additive: one immutable helper fn,
-- two BEFORE triggers, a column-privilege tightening on profiles,
-- and a non-enforcing data-cleanliness report for the phone-uniqueness
-- work that lands with the tenant-qualified login change.
--
-- Addresses (see docs/HAMURA_SECURITY_REVIEW.md):
--   D1  self role/scope escalation via update_own_profile      -> trigger + REVOKE
--   B2  tenant spoof on client INSERT                          -> enforce_row_tenant trigger
--   A1  cross-tenant phone scan (partial: DB helper + report;  the
--       login-with-identifier Edge Function change is the primary fix)
--
-- Rollback: sql/012_live_security_fixes_rollback.sql
-- Regression: sql/tests/012_regression.sql  (run immediately after apply)
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. normalize_phone(): the exact normalization used by the
--    login-with-identifier / register-school Edge Functions, as an
--    IMMUTABLE SQL function so it can back a (partial) unique index later.
--      JS:  value.replace(/[\s-]/g, "").replace(/^\+?00?/, "")
-- ------------------------------------------------------------
create or replace function public.normalize_phone(v text)
returns text
language sql
immutable
as $$
  select regexp_replace(
           regexp_replace(coalesce(v, ''), '[[:space:]-]', '', 'g'),
           '^\+?00?', '', ''
         )
$$;

revoke execute on function public.normalize_phone(text) from public;
grant execute on function public.normalize_phone(text) to authenticated, anon, service_role;


-- ------------------------------------------------------------
-- 2. D1 — prevent a user from escalating their OWN profile.
--    update_own_profile (002) only checks id = auth.uid() in WITH CHECK,
--    so a PATCH /profiles?id=eq.<me> {"role":"super_admin"} would slip
--    through the column privileges. Lock the sensitive columns for
--    self-updates by anyone who is not super_admin. service_role
--    (auth.uid() IS NULL) is unaffected — that is how create-user /
--    activate-account / register-school legitimately set these.
-- ------------------------------------------------------------
create or replace function public.prevent_profile_self_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- service_role / no session: allow (Edge Functions).
  if auth.uid() is null then
    return new;
  end if;

  -- Only guard the caller editing THEIR OWN row.
  if auth.uid() = new.id and not coalesce(is_super_admin(), false) then
    if new.role              is distinct from old.role
    or new.school_id         is distinct from old.school_id
    or new.branch_id         is distinct from old.branch_id
    or new.is_active         is distinct from old.is_active
    or new.activation_status is distinct from old.activation_status
    or new.hamura_id         is distinct from old.hamura_id then
      raise exception
        'لا يمكنك تعديل دورك أو مدرستك أو فرعك أو حالة حسابك بنفسك'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_prevent_profile_self_escalation on public.profiles;
create trigger trg_prevent_profile_self_escalation
  before update on public.profiles
  for each row execute function public.prevent_profile_self_escalation();

-- Column-level restriction of the sensitive profiles columns is done in
-- 012b (a column REVOKE here is a no-op because Supabase grants
-- table-level UPDATE to authenticated — see 012b header). The trigger
-- above is the in-transaction guard; 012b is the privilege guard.


-- ------------------------------------------------------------
-- 3. B2 — enforce_row_tenant(): on INSERT into any tenant-owned table,
--    a normal authenticated caller may NOT choose the school_id — it is
--    forced to their own. super_admin and service_role are exempt
--    (they legitimately create rows for arbitrary / not-yet-known tenants).
--    This is belt-and-braces over the RLS WITH CHECK, and also fixes any
--    tenant table whose policy set is momentarily incomplete.
-- ------------------------------------------------------------
create or replace function public.enforce_row_tenant()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_school uuid;
begin
  -- Edge Functions (service_role) and unauthenticated paths: leave as-is.
  if auth.uid() is null then
    return new;
  end if;

  -- Platform operator: may target any school explicitly.
  if coalesce(is_super_admin(), false) then
    return new;
  end if;

  v_my_school := my_school_id();

  if v_my_school is null then
    raise exception
      'تعذّر تحديد المدرسة لحسابك — لا يمكن إنشاء سجلات بدون سياق مدرسة'
      using errcode = '42501';
  end if;

  -- Force tenant ownership regardless of what the client sent.
  new.school_id := v_my_school;
  return new;
end;
$$;

-- Attach to every public table that has a school_id column (generated,
-- self-maintaining). Excludes tables without school_id (e.g. schools).
do $$
declare
  r record;
begin
  for r in
    select c.table_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public'
      and c.column_name = 'school_id'
      and t.table_type = 'BASE TABLE'
  loop
    execute format(
      'drop trigger if exists trg_enforce_row_tenant on public.%I', r.table_name
    );
    execute format(
      'create trigger trg_enforce_row_tenant before insert on public.%I
         for each row execute function public.enforce_row_tenant()',
      r.table_name
    );
  end loop;
end;
$$;


-- ------------------------------------------------------------
-- 4. A1 (report only) — phone-number tenant-collision inventory.
--    NON-ENFORCING. The tenant-qualified login (Edge Function) is the
--    functional fix; a partial unique index
--      (school_id, normalize_phone(phone)) where phone is not null
--    can only be added AFTER these collisions are resolved, so this
--    migration just measures them. Read the NOTICEs.
-- ------------------------------------------------------------
do $$
declare
  v_cross_school int;
  v_in_school    int;
begin
  select count(*) into v_cross_school
  from (
    select public.normalize_phone(phone) as np
    from public.profiles
    where phone is not null and public.normalize_phone(phone) <> ''
    group by public.normalize_phone(phone)
    having count(distinct school_id) > 1
  ) x;

  select count(*) into v_in_school
  from (
    select school_id, public.normalize_phone(phone) as np
    from public.profiles
    where phone is not null and public.normalize_phone(phone) <> ''
    group by school_id, public.normalize_phone(phone)
    having count(*) > 1
  ) y;

  raise notice '012 A1 report: % normalized phone(s) shared ACROSS schools; % duplicated WITHIN a school. Both must be 0 before the partial-unique index is added.', v_cross_school, v_in_school;
end;
$$;

commit;

-- ============================================================
-- POST-APPLY: run  sql/tests/012_regression.sql  now.
-- Then update docs/HAMURA_V1_IMPLEMENTATION_STATUS.md Phase 1 -> VERIFIED.
-- ============================================================
