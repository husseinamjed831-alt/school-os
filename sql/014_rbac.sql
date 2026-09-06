-- ============================================================
-- School OS — 014: RBAC foundation (V1 Phase 2, migration M2)
-- Depends on: 001 (profiles), 002 (my_role/is_super_admin), 003
--   (audit.log_change), 012b (profiles.role no longer client-writable —
--   assign_role() is now the path), 013 (current_school_id).
--
-- Role + Permission + Scope model. V1 simplification: a profile has
-- exactly one active role_assignment (backfilled 1:1 from profiles.role)
-- at that role's natural scope; profiles.role stays as a denormalised
-- mirror so existing RLS (my_role()) keeps working unchanged. has_perm()
-- is available for new policies (Phase 5+) and UI gating. Full
-- per-policy regeneration onto has_perm() is NOT done here (probe 3
-- showed the current RLS baseline is clean).
--
-- Rollback: sql/014_rbac_rollback.sql   Tests: sql/tests/014_rbac.sql
-- ============================================================

begin;

-- ---------- tables ----------
create table if not exists public.roles (
  code        text primary key,
  label_ar    text not null,
  is_platform boolean not null default false,
  rank        int not null                       -- higher = more powerful
);

create table if not exists public.permissions (
  code   text primary key,                        -- '<family>.<action>'
  family text not null,
  action text not null check (action in
    ('create','read','update','delete','approve','publish','export'))
);

create table if not exists public.role_permissions (
  role_code       text not null references public.roles(code) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  default_scope   text not null check (default_scope in
    ('PLATFORM','SCHOOL','BRANCH','CLASS','OWN_RECORD','CHILD_RECORD')),
  primary key (role_code, permission_code)
);

create table if not exists public.role_assignments (
  id           uuid primary key default gen_random_uuid(),
  school_id    uuid references public.schools(id) on delete cascade,   -- null for super_admin
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  role_code    text not null references public.roles(code),
  scope_type   text not null check (scope_type in
    ('PLATFORM','SCHOOL','BRANCH','CLASS','OWN_RECORD','CHILD_RECORD')),
  scope_id     uuid,
  granted_by   uuid references public.profiles(id) on delete set null,
  granted_at   timestamptz not null default now(),
  revoked_at   timestamptz,
  revoke_reason text
);
create index if not exists role_assignments_profile_idx on public.role_assignments(profile_id) where revoked_at is null;
create index if not exists role_assignments_school_idx  on public.role_assignments(school_id);

-- ---------- RLS ----------
alter table public.roles            enable row level security;
alter table public.permissions      enable row level security;
alter table public.role_permissions enable row level security;
alter table public.role_assignments enable row level security;

-- lookups: readable by any authenticated user; writable by super_admin only
create policy roles_read on public.roles for select using (auth.uid() is not null);
create policy roles_admin on public.roles for all using (is_super_admin()) with check (is_super_admin());
create policy perms_read on public.permissions for select using (auth.uid() is not null);
create policy perms_admin on public.permissions for all using (is_super_admin()) with check (is_super_admin());
create policy rp_read on public.role_permissions for select using (auth.uid() is not null);
create policy rp_admin on public.role_permissions for all using (is_super_admin()) with check (is_super_admin());

-- assignments: self-read; school_admin reads own school; super_admin all.
-- NO direct client INSERT/UPDATE/DELETE — assign_role()/revoke_role()
-- (SECURITY DEFINER) are the only write path.
create policy ra_self_read  on public.role_assignments for select using (profile_id = auth.uid());
create policy ra_super      on public.role_assignments for select using (is_super_admin());
create policy ra_admin_read on public.role_assignments for select
  using (my_role() in ('school_admin','branch_admin') and school_id = current_school_id());

create trigger audit_role_assignments after insert or update or delete on public.role_assignments
  for each row execute function audit.log_change();

-- role_assignments is created after 012, so it did not get 012's
-- generated trg_enforce_row_tenant — attach it here for consistency
-- (safe: assign_role() sets school_id to the caller's own anyway; the
-- backfill runs as postgres/auth.uid()=null and is exempt; super_admin
-- assignments with null school_id are exempt via is_super_admin()).
create trigger trg_enforce_row_tenant before insert on public.role_assignments
  for each row execute function public.enforce_row_tenant();

-- enforce_row_tenant fires on role_assignments too (it has school_id);
-- assign_role() is SECURITY DEFINER (auth.uid() still set) so it would be
-- rewritten — guard by allowing null school_id through for super_admin
-- assignments. The trigger already exempts is_super_admin(); for a
-- school_admin granting inside their own school, forcing school_id to
-- current_school_id() is correct anyway.

-- ---------- scope helper ----------
create or replace function public.scope_rank(p text) returns int
language sql immutable as $$
  select case p when 'PLATFORM' then 4 when 'SCHOOL' then 3
                when 'BRANCH' then 2 when 'CLASS' then 1 else 0 end
$$;

-- ---------- has_perm(code, scope) ----------
create or replace function public.has_perm(p_code text, p_scope text default 'SCHOOL')
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.role_assignments ra
    join public.role_permissions rp
      on rp.role_code = ra.role_code and rp.permission_code = p_code
    where ra.profile_id = auth.uid()
      and ra.revoked_at is null
      and (
        (public.scope_rank(p_scope) > 0 and public.scope_rank(ra.scope_type) >= public.scope_rank(p_scope))
        or (public.scope_rank(p_scope) = 0 and ra.scope_type = p_scope)
      )
  )
$$;
revoke execute on function public.has_perm(text,text) from public;
grant  execute on function public.has_perm(text,text) to authenticated, service_role;

-- ---------- profiles.role mirror maintenance ----------
-- profiles.role keeps the legacy 6-value CHECK from 001 (super_admin,
-- school_admin, branch_admin, teacher, student, parent) so existing RLS
-- (my_role()) is untouched. The *real* role lives in role_assignments;
-- this mirror maps the new roles down to their nearest legacy equivalent.
create or replace function public.legacy_role(p_role text) returns text
language sql immutable as $$
  select case p_role
    when 'school_owner'     then 'school_admin'
    when 'academic_manager' then 'school_admin'
    when 'finance_manager'  then 'school_admin'
    when 'staff'            then 'teacher'
    else p_role
  end
$$;

create or replace function public.recompute_profile_role(p_profile uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_role text;
begin
  select public.legacy_role(r.code) into v_role
  from public.role_assignments ra
  join public.roles r on r.code = ra.role_code
  where ra.profile_id = p_profile and ra.revoked_at is null
  order by r.rank desc
  limit 1;

  if v_role is not null then
    update public.profiles set role = v_role where id = p_profile and role is distinct from v_role;
  end if;
end;
$$;

create or replace function public.trg_role_assignments_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.recompute_profile_role(coalesce(new.profile_id, old.profile_id));
  return null;
end $$;
create trigger role_assignments_sync
  after insert or update of revoked_at on public.role_assignments
  for each row execute function public.trg_role_assignments_sync();

-- ---------- assign_role / revoke_role RPCs ----------
create or replace function public.assign_role(
  p_profile uuid, p_role text, p_scope_type text, p_scope_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_caller_role text := my_role();
  v_caller_school uuid := current_school_id();
  v_target_school uuid;
  v_new_rank int;
  v_caller_rank int;
  v_id uuid;
begin
  if v_caller is null then raise exception 'غير مصرح' using errcode='42501'; end if;

  select school_id into v_target_school from public.profiles where id = p_profile;
  if v_target_school is null and not is_super_admin() then
    raise exception 'المستخدم غير موجود' using errcode='42501';
  end if;

  select rank into v_new_rank    from public.roles where code = p_role;
  select rank into v_caller_rank from public.roles where code = v_caller_role;
  if v_new_rank is null then raise exception 'دور غير معروف' using errcode='22023'; end if;

  -- containment: only super_admin grants platform / owner; a grantor may
  -- only grant a role strictly weaker than their own, in their own school.
  if not is_super_admin() then
    if p_role in ('super_admin','school_owner') then
      raise exception 'صلاحياتك لا تسمح بمنح هذا الدور' using errcode='42501';
    end if;
    if v_caller_rank is null or v_new_rank >= v_caller_rank then
      raise exception 'لا يمكنك منح دور مساوٍ أو أعلى من دورك' using errcode='42501';
    end if;
    if v_target_school is distinct from v_caller_school then
      raise exception 'لا يمكن منح دور لمستخدم خارج مدرستك' using errcode='42501';
    end if;
    if v_caller_role = 'branch_admin' and p_role not in ('teacher','staff','student','parent') then
      raise exception 'مدير الفرع يمنح أدوار المعلم/الموظف/الطالب/ولي الأمر فقط' using errcode='42501';
    end if;
  end if;

  -- revoke any existing active assignment of the same role for this profile
  update public.role_assignments
     set revoked_at = now(), revoke_reason = 'superseded by assign_role'
   where profile_id = p_profile and role_code = p_role and revoked_at is null;

  insert into public.role_assignments
    (school_id, profile_id, role_code, scope_type, scope_id, granted_by)
  values
    (case when p_role = 'super_admin' then null else coalesce(v_target_school, v_caller_school) end,
     p_profile, p_role, p_scope_type, p_scope_id, v_caller)
  returning id into v_id;

  return v_id;
end;
$$;
revoke execute on function public.assign_role(uuid,text,text,uuid) from public;
grant  execute on function public.assign_role(uuid,text,text,uuid) to authenticated;

create or replace function public.revoke_role(p_assignment uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.role_assignments;
begin
  select * into v_row from public.role_assignments where id = p_assignment;
  if not found then raise exception 'التعيين غير موجود' using errcode='42501'; end if;

  if not is_super_admin() then
    if v_row.school_id is distinct from current_school_id()
       or my_role() not in ('school_admin','school_owner','branch_admin') then
      raise exception 'غير مصرح' using errcode='42501';
    end if;
  end if;

  update public.role_assignments
     set revoked_at = coalesce(revoked_at, now()),
         revoke_reason = coalesce(p_reason, 'revoked')
   where id = p_assignment;
end;
$$;
revoke execute on function public.revoke_role(uuid,text) from public;
grant  execute on function public.revoke_role(uuid,text) to authenticated;

-- ---------- seed: roles ----------
insert into public.roles (code, label_ar, is_platform, rank) values
  ('super_admin','مدير المنصة', true, 100),
  ('school_owner','مالك المدرسة', false, 90),
  ('school_admin','مدير المدرسة', false, 80),
  ('branch_admin','مدير الفرع', false, 70),
  ('academic_manager','المدير الأكاديمي', false, 60),
  ('finance_manager','المدير المالي', false, 55),
  ('teacher','معلم', false, 40),
  ('staff','موظف', false, 30),
  ('student','طالب', false, 20),
  ('parent','ولي أمر', false, 20)
on conflict (code) do nothing;

-- ---------- seed: permissions (V1 catalogue) ----------
insert into public.permissions (code, family, action)
select f || '.' || a, f, a
from (values
  ('tenant'),('subscription'),('user'),('role'),('session'),
  ('student'),('guardian'),('staff'),('academic_structure'),('enrollment'),
  ('attendance'),('attendance_correction'),('exam'),('assessment'),('grade'),
  ('grade_correction'),('report_card'),('fee_structure'),('invoice'),('payment'),
  ('refund'),('announcement'),('message'),('report'),('file'),('audit')
) fam(f)
cross join (values ('create'),('read'),('update'),('delete'),('approve'),('publish'),('export')) act(a)
on conflict (code) do nothing;

-- ---------- seed: role_permissions (coarse V1 grant matrix) ----------
-- super_admin: everything, PLATFORM
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'super_admin', code, 'PLATFORM' from public.permissions
on conflict do nothing;

-- school_owner + school_admin: everything except platform-only, SCHOOL
insert into public.role_permissions (role_code, permission_code, default_scope)
select r, code, 'SCHOOL' from public.permissions,
  (values ('school_owner'),('school_admin')) x(r)
where family not in ('subscription') or r = 'school_owner'
on conflict do nothing;
-- (school_owner also gets subscription.*; school_admin does not)

-- branch_admin: same families, BRANCH
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'branch_admin', code, 'BRANCH' from public.permissions
where family not in ('tenant','subscription','role','audit')
on conflict do nothing;

-- academic_manager: academic families, SCHOOL
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'academic_manager', code, 'SCHOOL' from public.permissions
where family in ('student','guardian','staff','academic_structure','enrollment',
                 'attendance','attendance_correction','exam','assessment','grade',
                 'grade_correction','report_card','announcement','message','report','file')
on conflict do nothing;

-- finance_manager: finance families, SCHOOL (+ read student/enrollment/report)
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'finance_manager', code, 'SCHOOL' from public.permissions
where family in ('fee_structure','invoice','payment','refund','report')
   or (family in ('student','guardian','enrollment') and action = 'read')
on conflict do nothing;

-- teacher: CLASS scope, teaching families
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'teacher', code, 'CLASS' from public.permissions
where (family in ('attendance','assessment','grade') and action in ('create','read','update'))
   or (family = 'attendance_correction' and action = 'create')
   or (family = 'grade_correction' and action = 'create')
   or (family in ('student','guardian','academic_structure','enrollment','report_card','exam') and action = 'read')
   or (family in ('announcement','message') and action in ('create','read','publish'))
on conflict do nothing;

-- staff: own record + read; explicit extra grants added per person later
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'staff', code, 'OWN_RECORD' from public.permissions
where family = 'user' and action in ('read','update')
on conflict do nothing;

-- student: read own
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'student', code, 'OWN_RECORD' from public.permissions
where (family in ('student','enrollment','attendance','grade','report_card','academic_structure','announcement') and action = 'read')
on conflict do nothing;

-- parent: read child
insert into public.role_permissions (role_code, permission_code, default_scope)
select 'parent', code, 'CHILD_RECORD' from public.permissions
where (family in ('student','enrollment','attendance','grade','report_card','invoice','payment','announcement') and action = 'read')
   or (family in ('message','attendance_correction') and action = 'create')
on conflict do nothing;

-- ---------- backfill role_assignments from profiles.role ----------
insert into public.role_assignments (school_id, profile_id, role_code, scope_type, scope_id, granted_by, granted_at)
select
  case when p.role = 'super_admin' then null else p.school_id end,
  p.id,
  p.role,
  case p.role
    when 'super_admin'  then 'PLATFORM'
    when 'branch_admin' then 'BRANCH'
    when 'teacher'      then 'SCHOOL'   -- class scope resolved live via fn_teaches_*
    when 'student'      then 'OWN_RECORD'
    when 'parent'       then 'CHILD_RECORD'
    else 'SCHOOL'
  end,
  case p.role when 'branch_admin' then p.branch_id else null end,
  null,
  p.created_at
from public.profiles p
where not exists (
  select 1 from public.role_assignments ra
  where ra.profile_id = p.id and ra.role_code = p.role and ra.revoked_at is null
);

-- earliest school_admin per school also becomes school_owner
insert into public.role_assignments (school_id, profile_id, role_code, scope_type, scope_id, granted_by, granted_at)
select distinct on (p.school_id) p.school_id, p.id, 'school_owner', 'SCHOOL', null, null, p.created_at
from public.profiles p
where p.role = 'school_admin' and p.school_id is not null
  and not exists (select 1 from public.role_assignments ra where ra.profile_id = p.id and ra.role_code = 'school_owner' and ra.revoked_at is null)
order by p.school_id, p.created_at asc;

commit;
