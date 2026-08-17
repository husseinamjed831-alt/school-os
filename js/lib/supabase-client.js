// ============================================================
// School OS — Supabase client bootstrap
//
// EDIT ONLY THE TWO LINES BELOW. Nothing else in this file needs to change.
//
//   SUPABASE_URL        Project Settings → API → Project URL
//   SUPABASE_ANON_KEY   Project Settings → API → Project API keys → anon/public
//
// Both of these are SAFE to put in frontend code — that is what they are
// for. The anon key is not a secret: it identifies your project, and every
// request made with it is still filtered by the RLS policies in sql/002_rls.sql
// onward. A user can only ever see/change what a policy explicitly allows,
// regardless of who holds this key.
//
// The one key that must NEVER appear in this file, or anywhere under js/,
// is the service_role key — it bypasses RLS entirely. It belongs only in
// Supabase Edge Function secrets (see supabase/functions/create-user),
// which Supabase injects automatically; you never paste it yourself.
// ============================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = "https://iabjbaaiumfahjdazvfd.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_yrOgPxZ_UG0daznRJI339g_iU3rY9jY";

// ============================================================
// Nothing below this line needs editing.
// ============================================================

// Every page's script is a module that imports this file first, so if
// credentials are still placeholders, createClient() throws immediately
// and every page silently renders blank with nothing but a console error —
// discovered while testing without a Supabase project connected. Fail
// loudly on-screen instead, in Arabic, with the fix.
if (SUPABASE_URL.startsWith("YOUR_") || SUPABASE_ANON_KEY.startsWith("YOUR_")) {
  document.body.innerHTML = `
    <div class="auth-page">
      <div class="auth-card">
        <div class="auth-logo">!</div>
        <h1 class="auth-title">الإعداد غير مكتمل</h1>
        <p class="auth-subtitle">لم يتم ربط المشروع بقاعدة بيانات Supabase بعد</p>
        <p class="text-muted" style="text-align:center; font-size:13px;">
          افتح js/lib/supabase-client.js وضع رابط المشروع (Project URL) ومفتاح anon الخاصين بمشروعك على Supabase،
          بعد إنشائه وتشغيل ملفات sql/ بالترتيب. التفاصيل الكاملة في README.md.
        </p>
      </div>
    </div>`;
  throw new Error("Supabase client not configured — fill in js/lib/supabase-client.js (see README.md)");
}

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true },
});
