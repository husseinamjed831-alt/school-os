# School OS — Architecture & Audit

## 0. Deployment status: 🟢 LIVE DATABASE VERIFIED

Connected to a real Supabase project ("مدرستي", `iabjbaaiumfahjdazvfd`,
ap-southeast-2). All 7 migrations applied, all 21 tables + 17 functions
confirmed live via `scripts/verify-supabase.mjs`, the `create-user` Edge
Function is deployed, `sql/tests/phase4_seed.sql` has real test tenants
seeded, and `sql/tests/phase4_rls_tests.sql` passed all 16 checks against
the live database (tenant/branch/teacher/student/parent isolation, audit
logging) — not a static review, an actual run. A real login through the
running app (school_admin_a) was also confirmed end to end: correct
dashboard, correct live counts, zero console errors.

One real bug surfaced only by this live pass and is now fixed for good:
seeding `auth.users` directly (bypassing normal signup) left four
token-related columns `NULL` instead of `''`, which GoTrue's Go code can't
scan and fails with an opaque "Database error querying schema" on login.
Fixed in `sql/tests/phase4_seed.sql`; documented there in case you ever
seed auth.users by hand elsewhere.

## 1. Audit result (Phase 1)

No pre-existing codebase was found anywhere on this machine. What exists is a
planning-only SpecKit bundle (`Downloads/files (1)/00-constitution.md`,
`01-plan.md`, `02-tasks.md`, `03-prompts.md`, `REQUIREMENTS.md`) describing a
smaller single-tenant vanilla-JS + Supabase school app. None of it was
implemented — no HTML/CSS/JS, no SQL run anywhere, no Supabase project, no
Docker, no tests, no CI.

**Conclusion:** this is a ground-up build, not a migration. Everything below
is the target architecture, built incrementally and verified at each step —
not a retrofit of something that doesn't exist.

## 2. Scope reality check

The full ask (37 sections: multi-tenant SaaS, AI copilot, risk prediction,
adaptive learning, exam engine, transportation GPS, multi-currency finance,
i18n, MFA, audit system, native desktop/mobile apps...) is a multi-year
commercial EdTech product. It will not fit in one pass. This document commits
to a concrete architecture so every future phase builds on the same
foundation instead of contradicting it, and the roadmap in §7 sequences the
remaining work honestly.

## 3. Stack decision

| Layer | Choice | Why |
|---|---|---|
| Database | Supabase Postgres | RLS gives real per-tenant row isolation without a bespoke authorization layer |
| Auth | Supabase Auth (+ MFA) | Built-in TOTP MFA, session management, no custom password handling |
| Backend logic | Supabase Edge Functions (Deno) | Server-side operations that need `service_role` (creating accounts, AI orchestration, notification dispatch) without standing up a separate Node server |
| Realtime | Supabase Realtime | Notification delivery, live bus-location updates (future) |
| Frontend | Vanilla JS, ES Modules, no build step | Matches the original constitution; avoids framework lock-in while the product shape is still moving |
| AI | Provider-agnostic service layer (`js/services/ai/`) behind one interface | Swappable model/provider later; app code never calls a provider SDK directly |
| Mobile/Desktop | PWA (installable web app) for now; native wrappers (Tauri/Capacitor) are a later, separate phase | Native apps are a real multi-week project each — not attempted in this pass |

**Why not a separate Node/Express backend:** Edge Functions cover every case
that needs `service_role` or an outbound call (create-user, send-notification,
AI-orchestrate) without a second deployable to operate and secure. If a case
shows up that Edge Functions can't handle, it gets called out explicitly, not
silently added.

## 4. Multi-tenant model

```
school (tenant)
  └── branch
        └── academic_year
              └── class          (grade level, per branch/year)
                    └── section  (e.g. "أ", "ب")
                          └── student
```

Every tenant-scoped table carries `school_id` (and `branch_id` where the
resource is branch-specific). RLS policies filter on `school_id = auth
tenant claim` — never on client-supplied values — so a compromised or buggy
frontend cannot cross tenant boundaries. See `sql/001_schema.sql` and
`sql/002_rls.sql`.

## 5. Roles & permission model

Roles from the original spec are kept and extended with tenant scope:

- `super_admin` — platform operator (us), not tied to a school. Reserved for
  cross-tenant support; not exposed in this phase's UI.
- `school_admin` — full control within their `school_id`.
- `branch_admin` — full control within their `branch_id`.
- `teacher` — read within assigned classes/sections, write attendance/grades
  for those.
- `student` — read own records only.
- `parent` — read own children's records only.

All authorization is enforced at the database via RLS — the frontend hiding
a button is UX, not security.

## 6. Audit logging

Every write to a sensitive table (`grades`, `attendance`, `payments`,
`students`, `profiles`) is captured by a single generic trigger
(`audit.log_change()`) into `audit.audit_log` — who, what, when, old value,
new value. See `sql/003_audit.sql`.

## 7. Roadmap (honest sequencing)

| Phase | Content | Status |
|---|---|---|
| 1 | Audit | done |
| 2 | Multi-tenant architecture + schema | done |
| 3 | Auth/RBAC/RLS + audit log | done |
| 3.5 | Vertical slice: school/branch/class/section/student CRUD under tenant isolation, admin UI | done |
| 4 | Attendance, flexible assessments/grading, Student 360, teacher/parent/student dashboards, deterministic analytics + risk engine v1 | done — see §9 |
| 5 | Notification engine (in-app already exists; real email/telegram dispatch via Edge Function) | next |
| 6 | Weekly schedule (day/period timetable) — the `schedule` table exists but has no UI yet | next |
| 7 | AI service layer wiring (needs your model/API key) + AI Copilot (scoped Q&A over the analytics layer built in Phase 4) | blocked on provider choice |
| 8 | Smart exam engine (question bank, auto-grading) | future |
| 9 | Finance (multi-currency fees/payments) | future |
| 10 | Transportation (buses/routes, GPS) | future |
| 11 | Executive/school-wide analytics dashboard | future |
| 12 | Adaptive learning, AI tutor | future |
| 13 | Native mobile/desktop wrappers | future |
| 14 | Load/security hardening, pen-test pass | future |

Each future phase gets implemented as real, working code with tests — not
scaffolding with `TODO`.

## 9. Phase 4 decisions worth knowing about

- **Teacher scoping is real, not cosmetic.** A teacher only sees/writes
  attendance, assessments, and behavior/notes for students in sections tied
  to a subject they're assigned to (`fn_teaches_section`/`fn_teaches_student`
  in `004_teacher_scoping.sql`). This replaced a too-broad Phase 3.5 policy
  that let any teacher touch any student in the school.
- **`grades` (from `001_schema.sql`) is superseded, not deleted.** The old
  hardcoded `exam_type` enum couldn't support school-configurable weighting,
  so `005_assessments.sql` adds `assessment_types` / `assessments` /
  `assessment_scores` alongside it. The app no longer writes to `grades` —
  it's left in place only because editing an already-applied migration file
  is the wrong move; if you're certain no one is querying it, dropping it is
  a fine follow-up migration later.
- **The risk score is staff-only by design**, enforced server-side
  (`fn_can_view_risk_score`), not just hidden in the UI. Parents and students
  see the underlying facts (attendance, grades) but never the score or its
  factor list — the intent is a raw unexplained number read by a parent as
  a verdict on their child, not a decision-support tool for staff with
  context. Reconsider this only as a deliberate product call, not a bug fix.
- **Security-definer RPC functions are revoked from `public` and re-granted
  to `authenticated` only** (`007_analytics_functions.sql`), including the
  Phase 3.5 helpers (`my_role()` etc.) that were left at Postgres's
  permissive default. Every analytics function re-checks the caller's
  permission itself — it does not trust that RLS on the underlying tables
  already covers it, because these functions run as `security definer` and
  bypass RLS by nature.
- **Not built this pass, deliberately:** the weekly day/period timetable UI
  (the `schedule` table exists, nothing reads/writes it yet — "today's
  classes" on the teacher/student dashboards is approximated from assigned
  subjects instead), staff attendance UI (the `staff_attendance` table +
  RLS exist, no page yet), and real notification dispatch (in-app bell
  already works; email/Telegram delivery is Phase 5).
- **I could not execute anything against a live database.** No Supabase
  credentials exist in this session. Every claim about RLS behavior is
  backed by reading the policies, not by running them — `sql/tests/
  phase4_rls_tests.sql` is how you get an actual pass/fail, not my
  assurance.

## 9.1 Teacher account activation (HAMURA ID + one-time code)

Added outside the phased roadmap above, on live production data (no
existing row deleted/altered beyond additive columns — see
`sql/010_account_activation.sql`). Replaces admin-typed initial passwords
for **teacher accounts only** (branch_admin/parent/student creation is
unchanged):

- `create-user` no longer takes a `password` for `role: "teacher"`. It
  generates a unique `hamura_id` (DB default via `generate_hamura_id()`),
  sets an unusable random `auth.users` password, marks
  `profiles.activation_status = 'pending'`, and issues a one-time
  activation code — hashed (SHA-256) into `account_activations`, plaintext
  returned exactly once in the response.
- `reissue-activation-code` (school_admin/branch_admin/super_admin, same
  tenant-scoping as `create-user`) invalidates any unused code and issues
  a new one — only while `activation_status = 'pending'`.
- `activate-account` (public, `--no-verify-jwt` — the teacher has no
  session yet) takes `hamura_id` + `code` + a new password, verifies the
  code (max 5 attempts, 72h expiry) and sets the real password.
- `admin/teacher-profile.html` shows the HAMURA ID and activation state to
  school_admin/branch_admin; `activate.html` is the public activation
  form, linked from the login page.
- Existing profiles were backfilled with a `hamura_id` and default to
  `activation_status = 'active'` — no current user is affected.

## 8. What I need from you before Phase 4+

- Supabase project URL + anon key (for `js/lib/supabase-client.js`)
- Confirmation this stack decision (§3) is acceptable, or redirect me
- For Phase 7 (AI): which model/provider to call (Claude via API key, or
  other) — nothing fakes this in the meantime
