-- ============================================================
-- School OS — 012b: profiles column-grant hardening (fixes 012's
-- ineffective column REVOKE).
--
-- Supabase's default bootstrap does `GRANT ALL ON ALL TABLES IN
-- SCHEMA public TO anon, authenticated`, so a column-level
-- `REVOKE UPDATE (col)` is a no-op — the table-level UPDATE grant
-- still covers every column. To actually restrict which columns an
-- authenticated client may write on `profiles`, revoke the
-- table-level UPDATE and re-grant a safe column allowlist.
--
-- Combined with 012's prevent_profile_self_escalation() trigger this
-- closes D1: role / school_id / branch_id / activation_status /
-- hamura_id become writable ONLY by service_role (create-user,
-- activate-account) and, later, the assign_role RPC.
--
-- Depends on: 001 (profiles), 012.
-- Rollback: sql/012b_profiles_grant_hardening_rollback.sql
-- ============================================================

begin;

-- authenticated: no table-wide UPDATE; only the harmless columns.
revoke update on public.profiles from authenticated;
grant  update (full_name, phone, is_active, telegram_chat_id)
       on public.profiles to authenticated;

-- authenticated has no business inserting/deleting/truncating profiles
-- (creation is service_role via the create-user Edge Function).
revoke insert, delete, truncate on public.profiles from authenticated;

-- anon should never write profiles at all (RLS already denies it; this
-- removes the latent grant too).
revoke insert, update, delete, truncate on public.profiles from anon;

commit;
