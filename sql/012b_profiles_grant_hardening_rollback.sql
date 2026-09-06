-- ============================================================
-- School OS — 012b ROLLBACK. Restores Supabase's default wide grants
-- on public.profiles for anon + authenticated.
-- ============================================================
begin;

revoke update (full_name, phone, is_active, telegram_chat_id)
  on public.profiles from authenticated;

grant insert, update, delete, truncate on public.profiles to authenticated;
grant insert, update, delete, truncate on public.profiles to anon;

commit;
