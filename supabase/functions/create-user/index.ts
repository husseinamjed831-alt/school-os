// School OS — create-user Edge Function
//
// Creates a login account (auth.users + profiles row) for a school_admin,
// branch_admin, teacher, parent, or student. This MUST run server-side
// because it needs the service_role key — the browser only ever holds the
// anon key.
//
// Auth rules (checked against the caller's own profile row, never trusted
// from the request body):
//   - super_admin   -> can create any role, for any school_id/branch_id
//                       (this is how a newly onboarded school gets its
//                       first school_admin — nobody else can bootstrap one)
//   - school_admin  -> can create branch_admin/teacher/parent/student,
//                       always scoped to their own school_id
//   - branch_admin  -> can create teacher/parent/student, always scoped
//                       to their own branch_id
//   - anyone else   -> rejected
//
// Deploy: supabase functions deploy create-user
// Secrets required (set via `supabase secrets set`) — SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are auto-injected by the platform for every
// Edge Function, you do not set them yourself.

import { createClient } from "npm:@supabase/supabase-js@2";

const ROLES_BY_CALLER = {
  super_admin: ["school_admin", "branch_admin", "teacher", "student", "parent"],
  school_admin: ["branch_admin", "teacher", "student", "parent"],
  branch_admin: ["teacher", "student", "parent"],
};

// Browsers calling this via supabase.functions.invoke() send a preflight
// OPTIONS request first. Without these headers on every response (including
// the preflight and every error path), the browser blocks the real request
// before it's even sent — the frontend just sees a generic network/CORS
// failure with no useful message.
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  // Everything below is wrapped so that ANY unexpected failure (a missing
  // secret, a downstream Supabase outage, a bug) still returns a clean JSON
  // response with CORS headers, instead of an uncaught exception that Deno
  // turns into a response the browser can't even read.
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "الطريقة غير مسموحة" }, 405);
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const callerJwt = authHeader.replace("Bearer ", "");
    if (!callerJwt) {
      return jsonResponse({ error: "غير مصرح: الرجاء تسجيل الدخول" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      // Should never happen on Supabase's platform (injected automatically),
      // but fail with a clear message rather than a cryptic client crash.
      return jsonResponse({ error: "إعداد الخادم غير مكتمل: متغيرات البيئة مفقودة" }, 500);
    }

    // Client scoped to the caller's own JWT — used only to identify who is calling.
    const callerClient = createClient(supabaseUrl, serviceRoleKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: authData, error: authError } = await callerClient.auth.getUser(callerJwt);
    if (authError || !authData?.user) {
      return jsonResponse({ error: "غير مصرح: جلسة غير صالحة" }, 401);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: callerProfile, error: profileError } = await admin
      .from("profiles")
      .select("role, school_id, branch_id")
      .eq("id", authData.user.id)
      .single();

    if (profileError || !callerProfile) {
      return jsonResponse({ error: "تعذر التحقق من صلاحيات المستخدم" }, 403);
    }
    const allowedRoles = ROLES_BY_CALLER[callerProfile.role as keyof typeof ROLES_BY_CALLER];
    if (!allowedRoles) {
      return jsonResponse({ error: "صلاحياتك لا تسمح بإنشاء حسابات" }, 403);
    }

    let body: {
      email?: string;
      password?: string;
      full_name?: string;
      role?: string;
      school_id?: string;
      branch_id?: string;
      phone?: string;
    };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "بيانات الطلب غير صالحة" }, 400);
    }

    const { email, password, full_name, role, branch_id, phone } = body;
    if (!email || !password || !full_name || !role) {
      return jsonResponse({ error: "الرجاء تعبئة كل الحقول المطلوبة" }, 400);
    }
    if (!allowedRoles.includes(role)) {
      return jsonResponse({ error: "دور غير مسموح لك بإنشائه" }, 403);
    }
    if (callerProfile.role === "branch_admin" && branch_id && branch_id !== callerProfile.branch_id) {
      return jsonResponse({ error: "لا يمكن إنشاء حساب خارج فرعك" }, 403);
    }
    if (callerProfile.role === "super_admin" && !body.school_id) {
      return jsonResponse({ error: "يجب تحديد المدرسة" }, 400);
    }

    const targetSchoolId = callerProfile.role === "super_admin" ? body.school_id : callerProfile.school_id;
    const targetBranchId = callerProfile.role === "branch_admin" ? callerProfile.branch_id : branch_id ?? null;

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (createError || !created?.user) {
      return jsonResponse({ error: `تعذر إنشاء الحساب: ${createError?.message ?? "خطأ غير معروف"}` }, 400);
    }

    const { error: insertError } = await admin.from("profiles").insert({
      id: created.user.id,
      school_id: targetSchoolId,
      branch_id: targetBranchId,
      role,
      full_name,
      phone: phone ?? null,
    });

    if (insertError) {
      await admin.auth.admin.deleteUser(created.user.id);
      return jsonResponse({ error: `تعذر إنشاء ملف المستخدم: ${insertError.message}` }, 400);
    }

    // Teachers additionally need a row in `teachers` — subjects.teacher_id
    // and every section-scoping check (fn_teaches_section/fn_teaches_student)
    // resolve through it, so a teacher profile without one is invisible to
    // their own classes.
    if (role === "teacher") {
      const { error: teacherError } = await admin.from("teachers").insert({
        school_id: targetSchoolId,
        branch_id: targetBranchId,
        profile_id: created.user.id,
      });
      if (teacherError) {
        await admin.from("profiles").delete().eq("id", created.user.id);
        await admin.auth.admin.deleteUser(created.user.id);
        return jsonResponse({ error: `تعذر إنشاء سجل المعلم: ${teacherError.message}` }, 400);
      }
    }

    return jsonResponse({ id: created.user.id }, 201);
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
