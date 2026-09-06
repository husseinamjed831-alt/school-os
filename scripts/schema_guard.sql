-- ============================================================
-- School OS — schema_guard: structural invariants that must hold after
-- every migration. Run in CI against a throwaway Postgres with
-- sql/001..NNN applied. RAISEs EXCEPTION on the first violation so the
-- job fails; prints a summary otherwise.
--
-- (docs/HAMURA_TEST_SPECIFICATIONS.md T-SCHEMA-GUARD-1 / T-SCHEMA-SECDEF-1)
-- ============================================================
do $$
declare
  v_bad text;
  v_count int;
begin
  ------------------------------------------------------------------
  -- 1. Every base table with a school_id column has RLS enabled.
  ------------------------------------------------------------------
  select string_agg(c.relname, ', ')
    into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  join information_schema.columns col
    on col.table_schema='public' and col.table_name=c.relname and col.column_name='school_id'
  where c.relkind='r' and not c.relrowsecurity;
  if v_bad is not null then
    raise exception 'schema_guard 1: tenant tables without RLS enabled: %', v_bad;
  end if;

  ------------------------------------------------------------------
  -- 2. Every such table has at least one policy whose predicate
  --    references a tenant function (my_school_id / current_school_id /
  --    is_super_admin) OR an ownership column (auth.uid via profile_id /
  --    parent_id).  (SELECT-only student/parent tables qualify via the latter.)
  ------------------------------------------------------------------
  select string_agg(t.table_name, ', ')
    into v_bad
  from (
    select distinct col.table_name
    from information_schema.columns col
    join pg_class c on c.relname = col.table_name
    join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
    where col.table_schema='public' and col.column_name='school_id' and c.relkind='r'
  ) t
  where not exists (
    select 1 from pg_policies p
    where p.schemaname='public' and p.tablename=t.table_name
      and (
        coalesce(p.qual,'')       ~* 'my_school_id|current_school_id|is_super_admin|auth\.uid|profile_id|parent_id'
        or coalesce(p.with_check,'') ~* 'my_school_id|current_school_id|is_super_admin|auth\.uid|profile_id|parent_id'
      )
  );
  if v_bad is not null then
    raise exception 'schema_guard 2: tenant tables with no tenant-scoped policy: %', v_bad;
  end if;

  ------------------------------------------------------------------
  -- 3. Every INSERT/UPDATE/ALL policy on a tenant table has a WITH CHECK.
  ------------------------------------------------------------------
  select string_agg(format('%s.%s', p.tablename, p.policyname), ', ')
    into v_bad
  from pg_policies p
  join information_schema.columns col
    on col.table_schema='public' and col.table_name=p.tablename and col.column_name='school_id'
  where p.schemaname='public'
    and p.cmd in ('ALL','INSERT','UPDATE')
    and p.with_check is null;
  if v_bad is not null then
    raise exception 'schema_guard 3: write policies missing WITH CHECK: %', v_bad;
  end if;

  ------------------------------------------------------------------
  -- 4. Every SECURITY DEFINER function sets search_path.
  ------------------------------------------------------------------
  select string_agg(p.proname, ', ')
    into v_bad
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace and n.nspname in ('public','audit')
  where p.prosecdef
    and coalesce(array_to_string(p.proconfig, ','), '') not like '%search_path%';
  if v_bad is not null then
    raise exception 'schema_guard 4: SECURITY DEFINER functions without SET search_path: %', v_bad;
  end if;

  ------------------------------------------------------------------
  -- 5. (post-012) enforce_row_tenant trigger present on every tenant table.
  --    Skipped automatically until 012 is in the applied set.
  ------------------------------------------------------------------
  if exists (select 1 from pg_proc where proname='enforce_row_tenant') then
    select string_agg(t.table_name, ', ')
      into v_bad
    from (
      select distinct col.table_name
      from information_schema.columns col
      join pg_class c on c.relname=col.table_name
      join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
      where col.table_schema='public' and col.column_name='school_id' and c.relkind='r'
        and col.table_name not in ('audit_events','domain_events','security_events','audit_export_log')
    ) t
    where not exists (
      select 1 from information_schema.triggers tg
      where tg.trigger_schema='public' and tg.event_object_table=t.table_name
        and tg.trigger_name='trg_enforce_row_tenant'
    );
    if v_bad is not null then
      raise exception 'schema_guard 5: tenant tables missing trg_enforce_row_tenant: %', v_bad;
    end if;
  end if;

  ------------------------------------------------------------------
  -- 6. (post-012) profiles sensitive columns not UPDATE-grantable to authenticated.
  ------------------------------------------------------------------
  if exists (select 1 from pg_proc where proname='prevent_profile_self_escalation') then
    select string_agg(g.column_name, ', ')
      into v_bad
    from information_schema.column_privileges g
    where g.table_schema='public' and g.table_name='profiles'
      and g.grantee='authenticated' and g.privilege_type='UPDATE'
      and g.column_name in ('role','school_id','branch_id','activation_status','hamura_id');
    if v_bad is not null then
      raise exception 'schema_guard 6: profiles sensitive columns still UPDATE-grantable to authenticated: %', v_bad;
    end if;
  end if;

  raise notice 'schema_guard: all invariants hold.';
end;
$$;
