-- ============================================================
-- School OS — 014 ROLLBACK. Drops the RBAC tables + functions.
-- profiles.role keeps its current values (it was only ever a mirror),
-- so RLS (my_role()) is unaffected.
-- ============================================================
begin;

drop trigger if exists role_assignments_sync on public.role_assignments;
drop trigger if exists audit_role_assignments on public.role_assignments;
drop trigger if exists trg_enforce_row_tenant on public.role_assignments;

drop function if exists public.assign_role(uuid,text,text,uuid);
drop function if exists public.revoke_role(uuid,text);
drop function if exists public.trg_role_assignments_sync();
drop function if exists public.recompute_profile_role(uuid);
drop function if exists public.legacy_role(text);
drop function if exists public.has_perm(text,text);
drop function if exists public.scope_rank(text);

drop table if exists public.role_assignments;
drop table if exists public.role_permissions;
drop table if exists public.permissions;
drop table if exists public.roles;

commit;
