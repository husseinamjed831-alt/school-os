// School OS — shared tenant-context helper for Edge Functions.
//
// SECURITY RULE (docs/HAMURA_SECURITY_REVIEW.md B3): no service_role code
// path may act on a school_id / branch_id / entity id taken from the
// request body. Resolve the caller's authorized context from their verified
// JWT + their own profiles row, and validate every id in the request
// against that context before use.
//
// Use in any JWT-verified function:
//
//   import { assertCallerContext } from "../_shared/tenant.ts";
//   const ctx = await assertCallerContext(req);          // throws on failure
//   // ctx = { userId, schoolId, branchId, role }
//   // then: verify body.some_student_id belongs to ctx.schoolId, etc.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

export type CallerContext = {
  userId: string;
  schoolId: string | null; // null only for super_admin
  branchId: string | null;
  role: string;
  admin: SupabaseClient; // service_role client, for post-validation work
};

export class ContextError extends Error {
  status: number;
  constructor(message: string, status = 401) {
    super(message);
    this.status = status;
  }
}

export async function assertCallerContext(req: Request): Promise<CallerContext> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    throw new ContextError("إعداد الخادم غير مكتمل", 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace("Bearer ", "").trim();
  if (!jwt) throw new ContextError("غير مصرح: الرجاء تسجيل الدخول", 401);

  const admin = createClient(supabaseUrl, serviceRoleKey);

  const { data: authData, error: authErr } = await admin.auth.getUser(jwt);
  if (authErr || !authData?.user) {
    throw new ContextError("غير مصرح: جلسة غير صالحة", 401);
  }

  const { data: profile, error: profErr } = await admin
    .from("profiles")
    .select("role, school_id, branch_id, is_active")
    .eq("id", authData.user.id)
    .single();

  if (profErr || !profile) {
    throw new ContextError("تعذر التحقق من صلاحيات المستخدم", 403);
  }
  if (!profile.is_active) {
    throw new ContextError("هذا الحساب معطّل", 403);
  }
  if (profile.role !== "super_admin" && !profile.school_id) {
    throw new ContextError("لا يوجد سياق مدرسة لحسابك", 403);
  }

  return {
    userId: authData.user.id,
    schoolId: profile.school_id,
    branchId: profile.branch_id,
    role: profile.role,
    admin,
  };
}

/** Assert that a row (by table + id) is owned by the caller's school. */
export async function assertRowInTenant(
  ctx: CallerContext,
  table: string,
  id: string,
): Promise<void> {
  if (ctx.role === "super_admin") return;
  const { data, error } = await ctx.admin
    .from(table)
    .select("school_id")
    .eq("id", id)
    .maybeSingle();
  if (error || !data || data.school_id !== ctx.schoolId) {
    // Same as "not found" — never reveal cross-tenant existence.
    throw new ContextError("غير موجود", 404);
  }
}
