#!/usr/bin/env node
// School OS — Supabase readiness check.
//
// Run:  node scripts/verify-supabase.mjs
//
// Reads the URL/anon key straight out of js/lib/supabase-client.js — the
// exact same file and exact same credentials the browser app uses — then
// makes read-only HTTPS requests using ONLY that key. It never reads, asks
// for, or prints a service_role key or anything else secret.
//
// This is not a mock: every check is a real network call to your Supabase
// project. If your project isn't reachable or isn't migrated yet, this
// script will tell you exactly that, with exit code 1.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CLIENT_FILE = join(__dirname, "..", "js", "lib", "supabase-client.js");

const RESULTS = [];
let hadFailure = false;

function record(status, label, detail) {
  RESULTS.push({ status, label, detail });
  if (status === "FAIL") hadFailure = true;
}

function printResults() {
  console.log("");
  for (const r of RESULTS) {
    const icon = r.status === "PASS" ? "✅" : r.status === "WARN" ? "⚠️ " : "❌";
    console.log(`${icon} ${r.label}`);
    if (r.detail) console.log(`   ${r.detail}`);
  }
  console.log("");
  console.log(hadFailure ? "RESULT: NOT READY — see ❌ items above" : "RESULT: all checks passed");
}

// Manual AbortController + setTimeout instead of AbortSignal.timeout(): the
// latter left a dangling internal timer handle that crashed Node on exit
// (Windows libuv assertion) — found by actually running this script against
// a live project instead of only reading it.
async function safeFetch(url, options) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    const res = await fetch(url, { ...options, signal: controller.signal });
    let body = null;
    try {
      body = await res.json();
    } catch {
      /* non-JSON response is fine, handled per-check */
    }
    return { ok: true, status: res.status, body };
  } catch (err) {
    return { ok: false, error: err.message };
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  // ---------- Step 1: read credentials the same way the app does ----------
  let text;
  try {
    text = readFileSync(CLIENT_FILE, "utf-8");
  } catch {
    console.error(`❌ Could not read ${CLIENT_FILE}`);
    process.exitCode = 1;
    return;
  }
  const SUPABASE_URL = text.match(/const SUPABASE_URL\s*=\s*"([^"]*)"/)?.[1];
  const SUPABASE_ANON_KEY = text.match(/const SUPABASE_ANON_KEY\s*=\s*"([^"]*)"/)?.[1];

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || SUPABASE_URL.startsWith("YOUR_") || SUPABASE_ANON_KEY.startsWith("YOUR_")) {
    console.error("❌ Supabase credentials are missing.");
    console.error(`   Edit ${CLIENT_FILE} and replace the two placeholder values.`);
    console.error("   See the 'Supabase Setup' section of README.md.");
    process.exitCode = 1;
    return;
  }
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(SUPABASE_URL.replace(/\/$/, "") + "/")) {
    console.error(`❌ SUPABASE_URL doesn't look like a Supabase project URL: ${SUPABASE_URL}`);
    process.exitCode = 1;
    return;
  }
  const BASE = SUPABASE_URL.replace(/\/$/, "");
  const authHeaders = { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` };

  // ---------- Step 2: connectivity ----------
  // GET /rest/v1/ (the API root/docs) requires a *secret* key on Supabase's
  // newer "publishable/secret key" system even when the publishable key is
  // perfectly valid for everything else — found by testing against a live
  // project using the new key format. /auth/v1/settings works the same way
  // for both the legacy anon key and the new publishable key, so it's the
  // reliable choice for "is this project reachable at all".
  const connCheck = await safeFetch(`${BASE}/auth/v1/settings`, { headers: authHeaders });
  if (!connCheck.ok) {
    record("FAIL", "Supabase connection", `Network error reaching ${BASE} — ${connCheck.error}`);
    printResults();
    process.exitCode = 1;
    return; // nothing else will work without connectivity
  }
  record("PASS", "Supabase connection", `Reached ${BASE} (HTTP ${connCheck.status})`);

  // ---------- Step 3: auth availability ----------
  if (connCheck.status === 200) {
    record("PASS", "Authentication service reachable", "GET /auth/v1/settings returned 200 — the key is valid");
  } else if (connCheck.status === 401) {
    record("FAIL", "Authentication service reachable", "GET /auth/v1/settings returned 401 — the key was rejected. Double-check it was copied in full (Settings → API → Publishable key, or legacy anon key).");
  } else {
    record("FAIL", "Authentication service reachable", `GET /auth/v1/settings returned ${connCheck.status}: ${JSON.stringify(connCheck.body)?.slice(0, 150)}`);
  }

  // ---------- Step 4: database (PostgREST) availability ----------
  // Any structured JSON response — success or a PostgREST error like
  // "table not found" — proves the database and PostgREST are both up.
  // Only a network failure or a raw auth rejection means they aren't.
  const dbCheck = await safeFetch(`${BASE}/rest/v1/schools?select=id&limit=1`, { headers: authHeaders });
  if (!dbCheck.ok) {
    record("FAIL", "Database (PostgREST) reachable", `Network error — ${dbCheck.error}`);
  } else if (dbCheck.status === 401 || dbCheck.status === 403) {
    record("FAIL", "Database (PostgREST) reachable", `HTTP ${dbCheck.status}: ${JSON.stringify(dbCheck.body)?.slice(0, 150)}`);
  } else {
    record("PASS", "Database (PostgREST) reachable", `HTTP ${dbCheck.status} — got a structured response, not a connection failure`);
  }

  // ---------- Step 5: required tables ----------
  const REQUIRED_TABLES = {
    "001_schema.sql": ["schools", "branches", "academic_years", "profiles", "classes", "sections", "teachers", "students", "subjects", "schedule", "attendance", "grades", "notifications"],
    "004_teacher_scoping.sql": ["staff_attendance"],
    "005_assessments.sql": ["assessment_types", "grading_scales", "assessments", "assessment_scores"],
    "006_student_records.sql": ["behavior_records", "teacher_notes"],
  };

  let anonRowLeak = false;
  for (const [migration, tables] of Object.entries(REQUIRED_TABLES)) {
    for (const table of tables) {
      const res = await safeFetch(`${BASE}/rest/v1/${table}?select=id&limit=5`, { headers: authHeaders });
      if (!res.ok) {
        record("FAIL", `Table "${table}" (${migration})`, `Network error — ${res.error}`);
        continue;
      }
      if (res.status === 200) {
        const rows = Array.isArray(res.body) ? res.body.length : 0;
        record("PASS", `Table "${table}" exists (${migration})`, rows > 0 ? `⚠ anon request returned ${rows} row(s) — see RLS check below` : "0 rows visible to an anonymous request, as expected");
        if (rows > 0) anonRowLeak = true;
      } else if (res.status === 404 || res.body?.code === "PGRST205") {
        record("FAIL", `Table "${table}" missing (${migration})`, `Run ${migration} — this table does not exist yet`);
      } else {
        record("WARN", `Table "${table}" — unexpected response (${migration})`, `HTTP ${res.status}: ${JSON.stringify(res.body)?.slice(0, 150)}`);
      }
    }
  }

  if (anonRowLeak) {
    record("FAIL", "RLS sanity check", "One or more tables returned real rows to an unauthenticated (anon) request. RLS should return zero rows with no session. Re-check that 002_rls.sql, 004, 005, and 006 all ran (they enable RLS and add policies).");
  } else {
    record("PASS", "RLS sanity check", "No table leaked rows to an anonymous request — RLS is filtering as expected");
  }

  // ---------- Step 6: required RPC functions ----------
  const REQUIRED_FUNCTIONS = {
    "002_rls.sql": [{ name: "my_role", args: {} }],
    "004_teacher_scoping.sql": [{ name: "fn_teaches_student", args: { p_student_id: "00000000-0000-0000-0000-000000000000" } }],
    "007_analytics_functions.sql": [
      { name: "fn_can_access_student", args: { p_student_id: "00000000-0000-0000-0000-000000000000" } },
      { name: "fn_student_risk_score", args: { p_student_id: "00000000-0000-0000-0000-000000000000" } },
    ],
  };

  for (const [migration, fns] of Object.entries(REQUIRED_FUNCTIONS)) {
    for (const fn of fns) {
      const res = await safeFetch(`${BASE}/rest/v1/rpc/${fn.name}`, {
        method: "POST",
        headers: { ...authHeaders, "Content-Type": "application/json" },
        body: JSON.stringify(fn.args),
      });
      if (!res.ok) {
        record("FAIL", `Function "${fn.name}" (${migration})`, `Network error — ${res.error}`);
      } else if (res.status === 404 || res.body?.code === "PGRST202") {
        record("FAIL", `Function "${fn.name}" missing (${migration})`, `Run ${migration} — this function does not exist yet`);
      } else {
        // Any other response (401/403 "permission denied", or a real result)
        // proves the function exists and is reachable via RPC — an anon
        // caller SHOULD be denied by the function's own internal auth check.
        record("PASS", `Function "${fn.name}" exists and is reachable (${migration})`, `HTTP ${res.status}`);
      }
    }
  }

  // ---------- Step 7: Edge Function deployment ----------
  const edgeCheck = await safeFetch(`${BASE}/functions/v1/create-user`, {
    method: "OPTIONS",
    headers: authHeaders,
  });
  if (!edgeCheck.ok) {
    record("FAIL", "Edge Function create-user", `Network error — ${edgeCheck.error}`);
  } else if (edgeCheck.status === 200) {
    record("PASS", "Edge Function create-user is deployed", "OPTIONS preflight answered 200 (CORS handled)");
  } else if (edgeCheck.status === 404) {
    record("FAIL", "Edge Function create-user is NOT deployed", "Run: supabase functions deploy create-user");
  } else {
    record("WARN", "Edge Function create-user — unexpected response", `HTTP ${edgeCheck.status} — it may be deployed but misbehaving; try the manual test in README.md`);
  }

  printResults();
  process.exitCode = hadFailure ? 1 : 0;
}

await main();
