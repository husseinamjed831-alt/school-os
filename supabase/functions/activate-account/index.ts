// School OS — activate-account Edge Function
//
// PUBLIC endpoint (no session — the teacher has never logged in yet). A
// teacher submits their HAMURA ID + the one-time activation code an admin
// gave them, plus a password of their own choosing. On success their
// auth.users password is set and profiles.activation_status becomes
// 'active'. Every failure path returns the same generic Arabic message so
// this can't be used to enumerate which HAMURA IDs exist.
//
// Deploy: supabase functions deploy activate-account --no-verify-jwt
// (public endpoint — no caller Authorization header exists to verify)

import { createClient } from "npm:@supabase/supabase-js@2";
import { ACTIVATION_MAX_ATTEMPTS, hashActivationCode } from "../_shared/activation.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const GENERIC_ERROR = "بيانات التفعيل غير صحيحة، تحقق من HAMURA ID والكود مع الإدارة";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "الطريقة غير مسموحة" }, 405);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "إعداد الخادم غير مكتمل: متغيرات البيئة مفقودة" }, 500);
    }

    let body: { hamura_id?: string; code?: string; new_password?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "بيانات الطلب غير صالحة" }, 400);
    }

    const hamuraId = body.hamura_id?.trim().toUpperCase();
    const code = body.code?.trim();
    const newPassword = body.new_password;

    if (!hamuraId || !code || !newPassword) {
      return jsonResponse({ error: "الرجاء تعبئة كل الحقول" }, 400);
    }
    if (newPassword.length < 8) {
      return jsonResponse({ error: "كلمة المرور يجب أن تكون 8 أحرف على الأقل" }, 400);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: profile } = await admin
      .from("profiles")
      .select("id, activation_status")
      .eq("hamura_id", hamuraId)
      .eq("role", "teacher")
      .maybeSingle();

    if (!profile || profile.activation_status !== "pending") {
      return jsonResponse({ error: GENERIC_ERROR }, 400);
    }

    const { data: activation } = await admin
      .from("account_activations")
      .select("id, code_hash, attempts, expires_at, used_at")
      .eq("profile_id", profile.id)
      .is("used_at", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!activation) {
      return jsonResponse({ error: GENERIC_ERROR }, 400);
    }
    if (new Date(activation.expires_at).getTime() < Date.now()) {
      return jsonResponse({ error: "انتهت صلاحية كود التفعيل، اطلب من الإدارة إعادة إصداره" }, 400);
    }
    if (activation.attempts >= ACTIVATION_MAX_ATTEMPTS) {
      return jsonResponse({ error: "تم تجاوز عدد المحاولات المسموح، اطلب من الإدارة إعادة إصدار الكود" }, 400);
    }

    const providedHash = await hashActivationCode(code);
    if (providedHash !== activation.code_hash) {
      await admin
        .from("account_activations")
        .update({ attempts: activation.attempts + 1 })
        .eq("id", activation.id);
      return jsonResponse({ error: GENERIC_ERROR }, 400);
    }

    const { error: passwordError } = await admin.auth.admin.updateUserById(profile.id, {
      password: newPassword,
    });
    if (passwordError) {
      return jsonResponse({ error: `تعذر تعيين كلمة المرور: ${passwordError.message}` }, 400);
    }

    await admin.from("account_activations").update({ used_at: new Date().toISOString() }).eq("id", activation.id);
    await admin.from("profiles").update({ activation_status: "active" }).eq("id", profile.id);

    return jsonResponse({ success: true }, 200);
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
