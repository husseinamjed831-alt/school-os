<!-- HAMURA — migration PR checklist -->

## What & why

<!-- short description; link the phase in docs/HAMURA_V1_IMPLEMENTATION_STATUS.md -->

## Migration checklist (delete if no `sql/**` change)

- [ ] New file is `sql/0NN_*.sql` (additive) — **no edit to `sql/001`–`011`**
- [ ] Paired `sql/0NN_*_rollback.sql` restores the exact prior state
- [ ] `sql/tests/0NN_regression.sql` added/updated
- [ ] `scripts/schema_guard.sql` still passes (CI: schema-guard)
- [ ] Wrapped in a single `BEGIN; … COMMIT;` **or** fully idempotent + re-runnable
- [ ] Compatibility window respected — **no `DROP COLUMN`/`DROP TABLE`** of anything in `HAMURA_CURRENT_STATE_FREEZE.md` §2
- [ ] Backfill (if any) is per-school, validated by row counts + same-tenant FK checks, reports unresolved rows rather than guessing
- [ ] RLS changes keep `USING` ∧ `WITH CHECK` symmetric and tenant-scoped
- [ ] Ran on a **staging clone of production data** first; validation queries green
- [ ] Pre-migration snapshot taken (`snapshots/M*-pre-*.dump`)
- [ ] `docs/HAMURA_V1_IMPLEMENTATION_STATUS.md` updated

## CONTRACT migration (`DROP COLUMN`/`DROP TABLE`) — extra gate

- [ ] **Second reviewer sign-off:** `@__________`
- [ ] Old `school-os` frontend fully retired (no client reads/writes the column)
- [ ] `grep` of both repos → zero references to the dropped field
- [ ] All SECDEF functions that referenced it redeployed + output-verified on staging
- [ ] Divergence job green ≥ 14 consecutive days in production
- [ ] Rollback (`ADD COLUMN` + backfill from new tables) rehearsed on staging
