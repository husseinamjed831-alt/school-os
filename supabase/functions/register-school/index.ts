// School OS — register-school Edge Function
//
// PUBLIC endpoint (no session) — a new school owner signs up for
// themselves, without a super_admin manually creating anything first. This
// is the only self-service entry point into the platform; every other
// account (branch_admin/teacher/student/parent) is still created by an
// existing admin via create-user.
//
// Creates, atomically (rolling back on any partial failure): a `schools`
// row (subscription_status = 'trial'), the owner's auth.users account, and
// their `profiles` row (role: school_admin). The owner picks their own
// password here — there is no HAMURA ID/activation-code step for this
// flow, unlike teacher accounts, because the owner is present and typing
// it themselves at signup time.
//
// Phone-first signup: the form only asks for a phone number, never an
// email. Supabase Auth's account record still needs *some* email under
// the hood, so one is synthesized deterministically from the phone number
// (never shown to the user, never used to send mail) — the owner logs
// back in with their phone number via login-with-identifier exactly like
// any other phone-registered account. Passing a real owner_email still
// works too (kept for flexibility), it just isn't what the form sends.
//
// Deploy: supabase functions deploy register-school --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function slugify(name: string): string {
  const base = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return base.length >= 3 ? base : "school";
}

// Matches login-with-identifier's normalizePhone so the same number always
// maps to the same synthetic email, whether it has spaces/dashes or not.
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
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "إعداد الخادم غير مكتمل: متغيرات البيئة مفقودة" }, 500);
    }

    let body: {
      school_name?: string;
      owner_full_name?: string;
      owner_email?: string;
      owner_password?: string;
      owner_phone?: string;
    };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "بيانات الطلب غير صالحة" }, 400);
    }

    const { school_name, owner_full_name, owner_email, owner_password, owner_phone } = body;
    if (!school_name || !owner_full_name || !owner_password || (!owner_phone && !owner_email)) {
      return jsonResponse({ error: "الرجاء تعبئة كل الحقول المطلوبة" }, 400);
    }
    if (owner_password.length < 8) {
      return jsonResponse({ error: "كلمة المرور يجب أن تكون 8 أحرف على الأقل" }, 400);
    }

    // No real email given (the normal path, from the signup form) -> the
    // phone number itself becomes the account's real identity, backed by a
    // synthetic, never-emailed address purely so auth.users has one.
    const authEmail = owner_email ?? `p${normalizePhone(owner_phone!)}@accounts.hamura.internal`;

    const admin = createClient(supabaseUrl, serviceRoleKey);

    // Slug uniqueness: try the plain slugified name first, then append a
    // short random suffix on collision (schools.slug is unique).
    let slug = slugify(school_name);
    const { data: slugTaken } = await admin.from("schools").select("id").eq("slug", slug).maybeSingle();
    if (slugTaken) {
      slug = `${slug}-${crypto.randomUUID().slice(0, 6)}`;
    }

    const { data: school, error: schoolError } = await admin
      .from("schools")
      .insert({ name: school_name, slug, subscription_status: "trial" })
      .select("id")
      .single();
    if (schoolError || !school) {
      return jsonResponse({ error: `تعذر إنشاء المدرسة: ${schoolError?.message ?? "خطأ غير معروف"}` }, 400);
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email: authEmail,
      password: owner_password,
      email_confirm: true,
    });
    if (createError || !created?.user) {
      await admin.from("schools").delete().eq("id", school.id);
      const alreadyExists = createError?.message?.toLowerCase().includes("already");
      return jsonResponse(
        {
          error: alreadyExists
            ? owner_email
              ? "هذا البريد الإلكتروني مستخدم بالفعل"
              : "رقم الهاتف هذا مستخدم بالفعل لحساب آخر"
            : `تعذر إنشاء الحساب: ${createError?.message ?? "خطأ غير معروف"}`,
        },
        400
      );
    }

    const { error: profileError } = await admin.from("profiles").insert({
      id: created.user.id,
      school_id: school.id,
      role: "school_admin",
      full_name: owner_full_name,
      phone: owner_phone ?? null,
    });
    if (profileError) {
      await admin.auth.admin.deleteUser(created.user.id);
      await admin.from("schools").delete().eq("id", school.id);
      return jsonResponse({ error: `تعذر إنشاء ملف المستخدم: ${profileError.message}` }, 400);
    }

    return jsonResponse({ school_id: school.id, profile_id: created.user.id }, 201);
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
