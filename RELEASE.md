# HAMURA V1.0.0 — Release Record

This file documents exactly what "Production" means as of this release, so
a rollback (of any single layer, or all three) can be done confidently
without guessing. Update it on every future release — don't let it go stale.

## This release

- **Git tag:** `v1.0.0`
- **Git commit:** `d35ca40`
- **Branch:** `master` (local) — the GitHub remote does not auto-deploy
  anything; Cloudflare Pages is a separate, manual `wrangler pages deploy`.

## Production endpoints

| Layer | Identity |
|---|---|
| Frontend | Cloudflare Pages project `hamura-pilot` — https://hamura-pilot.pages.dev |
| Database/Auth/Edge Functions | Supabase project `iabjbaaiumfahjdazvfd` ("مدرستي"), region ap-southeast-2 |

No other environment exists — this is the only production target. Never
create a second Cloudflare Pages project or a second Supabase project for
this app; that would split live user data across two places.

## What's deployed at this release

**Migrations applied, in order** (run manually via Supabase SQL Editor —
there is no automated migration runner):
`001_schema` → `002_rls` → `003_audit` → `004_teacher_scoping` →
`005_assessments` → `006_student_records` → `007_analytics_functions` →
`008_telegram` → `009_finance` → `010_account_activation` →
`011_v1_hardening`.

**Edge Functions deployed:** `create-user`, `reissue-activation-code`,
`activate-account` (`--no-verify-jwt`), `register-school`
(`--no-verify-jwt`), `telegram-webhook`, `telegram-dispatch`.

Run `node scripts/verify-supabase.mjs` any time to confirm all of the
above is actually live and matches this list — it's read-only (anon key
only) and safe to run against production whenever.

## Rollback procedures

### Frontend (Cloudflare Pages)

Every past deploy stays available. To roll back:
1. Cloudflare dashboard → Pages → `hamura-pilot` → **Deployments**.
2. Find the deployment before this release (tagged `production`, branch
   `main`).
3. Click **"Rollback to this deployment"** (or **"Retry deployment"** on
   an older one) — takes effect immediately, no rebuild needed.

Or from the CLI, redeploy an old commit's files directly:
```
git checkout <old-commit>
wrangler pages deploy . --project-name=hamura-pilot --branch=main
git checkout master
```
This only ever affects the frontend — it cannot touch the database.

### Database (Supabase)

There is **no automated down-migration** for this project (by design —
see README's "additive + backward-compatible" rule). Every migration
through this release was additive (new columns/tables/functions, no
column drops, no data rewrites), so:
- **Rolling back code without rolling back the schema is always safe** —
  older frontend/Edge Function code simply ignores the new columns
  (`hamura_id`, `activation_status`, `subscription_status`) and continues
  working exactly as it did before this release.
- If a specific migration must be reversed, write a new additive
  migration that undoes it (e.g. `drop column subscription_status`) —
  never edit or re-run an already-applied migration file. None of the
  011/010 changes are currently known to need this.

### Edge Functions (Supabase)

The Supabase dashboard (Functions → function name → **Deployments** tab)
keeps prior versions. To roll back one function:
```
git checkout <old-commit> -- supabase/functions/<name>
supabase functions deploy <name>
git checkout master -- supabase/functions/<name>
```

## Verifying a rollback (or this release) actually worked

1. `node scripts/verify-supabase.mjs` — all ✅.
2. Log in as an existing real school_admin — dashboard loads with real
   counts, no console errors.
3. Create a teacher → confirm a HAMURA ID + activation code are issued
   (not a manual password field).
4. Open `/admin/attendance.html` — daily overview renders for a real
   section.

## What this release did NOT touch

No existing row's `id` changed. No table was dropped. No RLS policy was
removed (only two were tightened — see git commit `d35ca40` message). No
real user or school data was read, exported, or modified by the release
process itself — verification and E2E testing used two disposable
self-registered test schools (`E2E Test School A/B`), fully deleted
(cascade) after testing, with zero residue in production.
