// School OS — login-with-identifier Edge Function  (v2: tenant-qualified)
//
// PUBLIC endpoint (no session yet — this IS how a session gets created).
// Log in with EITHER an email OR a phone number + the normal password.
// No SMS/OTP anywhere.
//
// v2 change (HAMURA V1 Phase 1, security review A1):
//   A phone number is NOT globally unique across tenants. Previously this
//   scanned every profile in the platform and required "exactly one match",
//   which (a) was a cross-tenant read and (b) broke phone login for BOTH
//   users whenever the same number existed in two schools.
//   Now:
//     - email identifier            -> unchanged (emails are globally unique)
//     - phone + `school_code`       -> resolution scoped to that one school
//     - phone, no `school_code`,
//       matches users in ONE school -> still works (backwards compatible)
//     - phone, no `school_code`,
//       matches >1 school           -> rejected: "provide your school code"
//   Every failure path returns the SAME generic error (no oracle), except
//   the explicit "needs school code" disambiguation prompt.
//
// Deploy: supabase functions deploy login-with-identifier --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const GENERIC_ERROR = "البريد الإلكتروني/رقم الهاتف أو كلمة المرور غير صحيحة";
const NEED_SCHOOL_CODE =
  "رقم الهاتف هذا مستخدم في أكثر من مدرسة — الرجاء إدخال رمز مدرستك";

function looksLikeEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

// Must stay identical to public.normalize_phone() in sql/012 and to
// register-school's normalizePhone().
function normalizePhone(value: string): string {
  return value.replace(/[\s-]/g, "").replace(/^\+?00?/, "");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "الطريقة غير مسموحة" }, 405);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return jsonResponse({ error: "إعداد الخادم غير مكتمل: متغيرات البيئة مفقودة" }, 500);
    }

    let body: { identifier?: string; password?: string; school_code?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "بيانات الطلب غير صالحة" }, 400);
    }

    const identifier = body.identifier?.trim();
    const password = body.password;
    const schoolCode = body.school_code?.trim().toLowerCase() || null;
    if (!identifier || !password) {
      return jsonResponse({ error: "الرجاء تعبئة كل الحقول" }, 400);
    }

    let email: string;

    if (looksLikeEmail(identifier)) {
      email = identifier;
    } else {
      const admin = createClient(supabaseUrl, serviceRoleKey);
      const normalized = normalizePhone(identifier);

      // Resolve the tenant scope first.
      let scopedSchoolId: string | null = null;
      if (schoolCode) {
        const { data: school } = await admin
          .from("schools")
          .select("id")
          .eq("slug", schoolCode)
          .maybeSingle();
        if (!school) {
          // unknown school code -> same generic error (no oracle)
          return jsonResponse({ error: GENERIC_ERROR }, 400);
        }
        scopedSchoolId = school.id;
      }

      // Pull only phone-bearing profiles, scoped to the school when we have one.
      let q = admin.from("profiles").select("id, phone, school_id").not("phone", "is", null);
      if (scopedSchoolId) q = q.eq("school_id", scopedSchoolId);
      const { data: rows } = await q;

      const matched = (rows ?? []).filter(
        (p) => p.phone && normalizePhone(p.phone) === normalized,
      );

      if (matched.length === 0) {
        return jsonResponse({ error: GENERIC_ERROR }, 400);
      }
      if (matched.length > 1) {
        // Ambiguous. If it spans multiple schools, ask for the code;
        // if it is duplicated inside one school, that is a data defect
        // and we still refuse generically.
        const schools = new Set(matched.map((m) => m.school_id));
        if (!scopedSchoolId && schools.size > 1) {
          return jsonResponse({ error: NEED_SCHOOL_CODE, need_school_code: true }, 409);
        }
        return jsonResponse({ error: GENERIC_ERROR }, 400);
      }

      const { data: userData, error: userError } = await admin.auth.admin.getUserById(
        matched[0].id,
      );
      if (userError || !userData?.user?.email) {
        return jsonResponse({ error: GENERIC_ERROR }, 400);
      }
      email = userData.user.email;
    }

    // The real password check — a fresh anon-key client, exactly what the
    // browser's supabase.auth.signInWithPassword() would do.
    const anonClient = createClient(supabaseUrl, anonKey);
    const { data: signInData, error: signInError } =
      await anonClient.auth.signInWithPassword({ email, password });
    if (signInError || !signInData?.session) {
      return jsonResponse({ error: GENERIC_ERROR }, 400);
    }

    return jsonResponse(
      {
        access_token: signInData.session.access_token,
        refresh_token: signInData.session.refresh_token,
      },
      200,
    );
  } catch (err) {
    return jsonResponse({ error: `خطأ غير متوقع: ${String(err)}` }, 500);
  }
});

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}
