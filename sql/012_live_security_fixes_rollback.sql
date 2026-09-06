-- ============================================================
-- School OS — 012 ROLLBACK
-- Restores the exact pre-012 state. No data was changed by 012, so this
-- only drops the added objects and re-grants the profiles columns.
-- ============================================================

begin;

-- 3. enforce_row_tenant triggers (generated list) + function
do $$
declare r record;
begin
  for r in
    select event_object_table as table_name
    from information_schema.triggers
    where trigger_schema = 'public'
      and trigger_name = 'trg_enforce_row_tenant'
  loop
    execute format('drop trigger if exists trg_enforce_row_tenant on public.%I', r.table_name);
  end loop;
end;
$$;
drop function if exists public.enforce_row_tenant();

-- 2. self-escalation guard.
-- NOTE: 012's `revoke update (cols)` was a no-op (Supabase grants
-- table-level UPDATE), so there is nothing to re-grant here. The real
-- column restriction is 012b — roll that back separately and FIRST.
drop trigger if exists trg_prevent_profile_self_escalation on public.profiles;
drop function if exists public.prevent_profile_self_escalation();

-- 1. helper
drop function if exists public.normalize_phone(text);

commit;
