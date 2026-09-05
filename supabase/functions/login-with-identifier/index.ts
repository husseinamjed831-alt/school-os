// School OS — login-with-identifier Edge Function
//
// PUBLIC endpoint (no session yet — this IS how a session gets created).
// Lets a user log in with either their email OR their phone number, using
// their normal password — no SMS/OTP involved anywhere, so this has zero
// per-message cost and doesn't need an SMS provider.
//
// `profiles.phone` has no uniqueness constraint (never did — adding one
// now could fail against real existing duplicate/blank phone numbers), so
// this resolves phone -> email server-side and refuses to guess when a
// phone number matches zero or more than one profile. It never reveals to
// the caller whether the identifier existed at all: an unknown phone, an
// ambiguous phone, and a wrong password all return the exact same generic
// error, exactly like normal email/password login already does.
//
// Deploy: supabase functions deploy login-with-identifier --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const GENERIC_ERROR = "البريد الإلكتروني/رقم الهاتف أو كلمة المرور غير صحيحة";

function looksLikeEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

// Loose match: strips spaces/dashes and an optional leading "+" or "00" so
// "077 3001 8178", "0773-001-8178", and "+9647730018178" can all still
// find the same stored "07730018178" without forcing every admin/import to
// re-normalize existing phone numbers first.
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

    let body: { identifier?: string; password?: string };
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ error: "بيانات الطلب غير صالحة" }, 400);
    }

    const identifier = body.identifier?.trim();
    const password = body.password;
    if (!identifier || !password) {
      return jsonResponse({ error: "الرجاء تعبئة كل الحقول" }, 400);
    }

    let email: string;

    if (looksLikeEmail(identifier)) {
      email = identifier;
    } else {
      const admin = createClient(supabaseUrl, serviceRoleKey);
      const normalized = normalizePhone(identifier);

      const { data: matches } = await admin
        .from("profiles")
        .select("id, phone")
        .not("phone", "is", null);

      const matched = (matches ?? []).filter((p) => p.phone && normalizePhone(p.phone) === normalized);
      if (matched.length !== 1) {
        // Zero matches (unknown number) or more than one (ambiguous,
        // pre-existing duplicate phone numbers) — same generic error either
        // way, same as an unknown email would get.
        return jsonResponse({ error: GENERIC_ERROR }, 400);
      }

      const { data: userData, error: userError } = await admin.auth.admin.getUserById(matched[0].id);
      if (userError || !userData?.user?.email) {
        return jsonResponse({ error: GENERIC_ERROR }, 400);
      }
      email = userData.user.email;
    }

    // The actual password check — a fresh anon-key client, same as the
    // browser's own supabase.auth.signInWithPassword() would do. This
    // function only ever resolves *which* email to check, never bypasses
    // the real password verification.
    const anonClient = createClient(supabaseUrl, anonKey);
    const { data: signInData, error: signInError } = await anonClient.auth.signInWithPassword({ email, password });
    if (signInError || !signInData?.session) {
      return jsonResponse({ error: GENERIC_ERROR }, 400);
    }

    return jsonResponse(
      {
        access_token: signInData.session.access_token,
        refresh_token: signInData.session.refresh_token,
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
