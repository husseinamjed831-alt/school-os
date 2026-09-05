// School OS — reissue-activation-code Edge Function
//
// Lets a school_admin/branch_admin/super_admin generate a fresh HAMURA
// activation code for a teacher whose account is still pending activation
// (first code lost, expired, or too many failed attempts). Requires
// service_role because it writes account_activations. Never touches an
// already-active account — reactivating a working login is a separate,
// unrequested feature and out of scope here.
//
// Deploy: supabase functions deploy reissue-activation-code

import { createClient } from "npm:@supabase/supabase-js@2";
import { ACTIVATION_CODE_TTL_MS, generateActivationCode, hashActivationCode } from "../_shared/activation.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

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
      return jsonResponse({ error: "إعداد الخادم غير مكتمل: متغيرات البيئة مفقودة" }, 500);
    }

    const callerClient = createClient(supabaseUrl, serviceRoleKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: authData, error: authError } = await callerClient.auth.getUser(callerJwt);
    if (authError || !authData?.user) {
      return jsonResponse({ error: "غير مصرح: جلسة غير صالحة" }, 401);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: callerProfile, error: callerError } = await admin
      .from("profiles")
      .select("role, school_id, branch_id")
      .eq("id", authData.user.id)
      .single();
    if (callerError || !callerProfile) {
      return jsonResponse({ error: "تعذر التحقق من صلاحيات المستخدم" }, 403);
    }
    if (!["super_admin", "school_admin", "branch_admin"].includes(callerProfile.role)) {
      return jsonResponse({ error: "صلاحياتك لا تسمح بهذا الإجراء" }, 403);
    }

    let body: { profile_id?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "بيانات الطلب غير صالحة" }, 400);
    }
    if (!body.profile_id) {
      return jsonResponse({ error: "الرجاء تحديد المستخدم" }, 400);
    }

    const { data: target, error: targetError } = await admin
      .from("profiles")
      .select("id, role, school_id, branch_id, activation_status, hamura_id")
      .eq("id", body.profile_id)
      .single();
    if (targetError || !target) {
      return jsonResponse({ error: "المستخدم غير موجود" }, 404);
    }
    if (target.role !== "teacher") {
      return jsonResponse({ error: "هذا الإجراء متاح فقط لحسابات المعلمين" }, 400);
    }
    if (target.activation_status !== "pending") {
      return jsonResponse({ error: "هذا الحساب مفعّل بالفعل" }, 400);
    }

    // Scope check — mirrors create-user's own-tenant rules exactly.
    if (callerProfile.role === "school_admin" && target.school_id !== callerProfile.school_id) {
      return jsonResponse({ error: "لا يمكن إدارة حساب خارج مدرستك" }, 403);
    }
    if (callerProfile.role === "branch_admin" && target.branch_id !== callerProfile.branch_id) {
      return jsonResponse({ error: "لا يمكن إدارة حساب خارج فرعك" }, 403);
    }

    // Invalidate any still-unused codes for this profile before issuing a
    // new one — a previously leaked/expired code must stop working.
    await admin.from("account_activations").delete().eq("profile_id", target.id).is("used_at", null);

    const activationCode = generateActivationCode();
    const { error: insertError } = await admin.from("account_activations").insert({
      profile_id: target.id,
      school_id: target.school_id,
      code_hash: await hashActivationCode(activationCode),
      expires_at: new Date(Date.now() + ACTIVATION_CODE_TTL_MS).toISOString(),
      created_by: authData.user.id,
    });
    if (insertError) {
      return jsonResponse({ error: `تعذر إنشاء كود التفعيل: ${insertError.message}` }, 400);
    }

    return jsonResponse(
      {
        hamura_id: target.hamura_id,
        activation_code: activationCode,
        expires_at_hours: ACTIVATION_CODE_TTL_MS / 3600000,
      },
      200
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
