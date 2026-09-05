# School OS

Multi-tenant school management platform. See `ARCHITECTURE.md` for the full
audit, stack decision, and phased roadmap.

# Supabase Setup

Do these in order. Nothing here needs anything invented — every value comes
from your own Supabase project.

### 1. Create a Supabase project

Go to [supabase.com](https://supabase.com), sign in, and create a new
project. Wait for it to finish provisioning (a couple of minutes).

### 2. Find your Project URL

In the project dashboard: **Settings → API → Project URL**. It looks like
`https://xxxxxxxxxxxx.supabase.co`.

### 3. Find your anon/public key

Same page: **Settings → API → Project API keys → `anon` `public`**. This is
**not** a secret — it's designed to be embedded in frontend code, and every
request made with it is still filtered by RLS. Do **not** copy the
`service_role` key for this step; that one must never leave the Edge
Function secrets.

### 4. Put the two values in the project

Open `js/lib/supabase-client.js`. Near the top there are two lines:

```js
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

Replace the two placeholder strings with the values from steps 2–3. Don't
touch anything else in the file.

### 5. Apply the database migrations

In the Supabase dashboard: **SQL Editor → New query**. Run each of these
files **one at a time, in this exact order**, waiting for each to finish
successfully before starting the next:

1. `sql/001_schema.sql`
2. `sql/002_rls.sql`
3. `sql/003_audit.sql`
4. `sql/004_teacher_scoping.sql`
5. `sql/005_assessments.sql`
6. `sql/006_student_records.sql`
7. `sql/007_analytics_functions.sql`
8. `sql/010_account_activation.sql`
9. `sql/011_v1_hardening.sql`

For each: open the file, copy its full contents, paste into a new SQL
Editor query, click **Run**, confirm it says success with no red error
text, then move to the next file. Each file's own header comment lists
which earlier files it depends on, if you want to double check.

**If one fails partway through:** stop — don't just re-run it. Read the
actual error message, and either fix the one statement it points at (if
it's an obvious typo) or bring the exact error text back for a proper
additive fix migration. Blindly re-running a partially-applied file will
usually just fail again on "already exists" for whatever did succeed.

### 6. Deploy the Edge Functions

This needs the Supabase CLI and Deno, which are **not installed by
default** — install them first if you haven't:
- Supabase CLI: see [supabase.com/docs/guides/cli](https://supabase.com/docs/guides/cli)
- Deno: see [deno.com](https://deno.com) (only needed if the CLI asks for it)

Then, from the project root:

```
supabase login
supabase link --project-ref <your-project-ref>
supabase functions deploy create-user
supabase functions deploy reissue-activation-code
supabase functions deploy activate-account --no-verify-jwt
supabase functions deploy register-school --no-verify-jwt
```

`activate-account` is the one function that must be reachable with **no**
caller session — a teacher activating their account for the first time
has never logged in — hence `--no-verify-jwt` on that one only. The other
two stay behind normal JWT verification (they check the caller's own
`profiles` role internally, same as `create-user` always has).

The project ref is the `xxxxxxxxxxxx` part of your Project URL. You do
**not** set `SUPABASE_URL` or `SUPABASE_SERVICE_ROLE_KEY` yourself —
Supabase injects both into every Edge Function automatically.

### 7. Bootstrap the platform owner (first `super_admin`)

There is deliberately no UI for this — it's the one account that has to
exist before anything else can. In Supabase dashboard: **Authentication →
Users → Add user** (check "Auto Confirm User"), then in the **SQL Editor**:

```sql
insert into profiles (id, role, full_name)
values ('<the new user''s id, shown in the Authentication → Users list>', 'super_admin', 'Platform Owner');
```

### 8. Test that Authentication actually works

Serve the project locally (see "Running it locally" below), open the login
page, and sign in with the super_admin account from step 7. Landing on
`/admin/schools.html` confirms: the anon key is valid, migrations 001–003
are in place, and Auth is wired up correctly. If it fails, run the
verification script below before troubleshooting further by hand.

## Running it locally

ES modules and the `/js/...` absolute paths need a real HTTP origin, not
`file://`. Any static server works:

```
npx serve .
```

or deploy to Vercel/Netlify as a static site.

# Verification

One command checks the whole backend is actually wired up — Supabase
connectivity, Auth availability, every required table, every required RPC
function, RLS not leaking rows to anonymous requests, and whether the Edge
Function is deployed. It only ever uses the anon key (same as the browser
app), never `service_role`, and never prints your key back to you.

```
node scripts/verify-supabase.mjs
```

Read top to bottom: ✅ = fine, ❌ = something's missing and the line tells
you which migration/step to (re-)run, ⚠️ = worth a look but not necessarily
broken. Exit code is `0` only if everything passed.

# Test data + RLS tests

Two SQL files exist specifically to prove RLS actually works, not just that
it reads correctly:

1. **`sql/tests/phase4_seed.sql`** — run once in the SQL Editor (after
   migrations 001–007). Creates two fake tenants with fixed, known IDs:
   School A (1 branch, 1 year, 2 classes, 2 sections, 2 teachers, 4
   students, 2 parents) and School B (a minimal second tenant whose only
   job is proving School A can never see it). Every seeded account's
   email/password is listed at the bottom of the file — all fake, all
   `@test.schoolos.local`, password `Test1234!` for every one of them. Safe
   to re-run any time; it cleans up its own previous rows first.
2. **`sql/tests/phase4_rls_tests.sql`** — run after the seed, via the
   **`psql` CLI** (the web SQL Editor doesn't support the `\set` syntax it
   uses): `psql "<connection string from Settings → Database>" -f
   sql/tests/phase4_rls_tests.sql`. It impersonates each seeded role in turn
   and asserts real PASS/FAIL for tenant isolation, branch isolation,
   teacher section-scoping, student-to-student isolation, parent-to-parent
   isolation, unauthorized-write rejection, and audit logging — then rolls
   the whole transaction back, so it never leaves your data changed.

## Manual test path (vertical slice)

You can also walk through this by hand instead of/in addition to the seed:

1. Log in as the super_admin you bootstrapped in step 7 above → lands on
   `/admin/schools.html`.
2. Create a school → appears in the table immediately.
3. Click "إنشاء مدير" on that school's row → create a school_admin account.
4. Log out, log in as that school_admin → lands on `/admin/dashboard.html`
   with stat cards for students/teachers/branches/sections (all zero at
   first).
5. Go to "الهيكل الأكاديمي" → add a branch, then an academic year, then a
   class (referencing that branch + year), then a section (referencing that
   class).
6. Go to "الطلاب" → add a student, assign the section created above. Confirm
   it appears in the table with the correct class/section label.
7. Go to "المستخدمون" → create a teacher and a parent account.
8. Edit the student again and assign the parent you just created.
9. Log out, log in as the parent → their dashboard shows the linked child
   by name and section.
10. **Tenant isolation check:** create a second school (as super_admin) with
    its own school_admin, log in as that second school_admin, and confirm
    the first school's students/branches/classes are completely invisible —
    this is RLS doing its job, not client-side filtering.

## Phase 4 additions — manual test path

Continuing from step 8 above (a school_admin, a section with a student, a
teacher and a parent account exist):

11. As school_admin, go to "الهيكل الأكاديمي" → "المواد الدراسية" → create a
    subject for the class, assign it to the teacher you created. This is
    required — a teacher with no assigned subject can't see any section.
12. Go to "إعدادات التقييم" → add at least one assessment type (e.g. "واجب"
    100%) so a teacher has something to grade against.
13. Log in as the teacher → "الحضور" → pick the section + today's date →
    mark each student → save. Reload the page and confirm the statuses
    persisted.
14. Still as the teacher → "التقييمات والدرجات" → pick the subject → "+
    تقييم جديد" → create one → "إدخال الدرجات" → enter a score for each
    student, mark one "لم يُسلَّم" → save.
15. Open the student's profile ("الملف الكامل" from `admin/students.html`,
    or the "طلاب بحاجة إلى متابعة" link on the teacher dashboard) → confirm
    attendance rate, the graded subject's weighted percent, and (staff-only)
    the risk score with its listed factors all show real numbers, not
    placeholders.
16. Log in as the parent → dashboard shows the same attendance/grade numbers
    for their child → click through to the child's profile → confirm no
    risk score section appears (staff-only by design) but behavior/notes
    do, if any were added.
17. Log in as the student → dashboard shows their own numbers, no risk
    score, no other students' data reachable by URL-guessing (RLS blocks
    it even if you construct the URL).
