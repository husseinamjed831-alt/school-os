// School OS — authentication + route guarding.
import { supabase } from "./supabase-client.js";

const ROLE_HOME = {
  super_admin: "/admin/schools.html",
  school_admin: "/admin/dashboard.html",
  branch_admin: "/admin/dashboard.html",
  teacher: "/teacher/dashboard.html",
  student: "/student/dashboard.html",
  parent: "/parent/dashboard.html",
};

/**
 * @param {string} email
 * @param {string} password
 * @returns {Promise<{profile: object}>}
 */
export async function login(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
  const profile = await verifyActiveSessionOrSignOut();
  return { profile, session: data.session };
}

/**
 * Same as login(), but accepts either an email or a phone number in one
 * field — resolution happens server-side (login-with-identifier Edge
 * Function) since `profiles.phone` isn't guaranteed unique and must never
 * be looked up directly with the anon key. No SMS/OTP involved; the
 * password check is the exact same one login() uses.
 * @param {string} identifier
 * @param {string} password
 * @returns {Promise<{profile: object}>}
 */
export async function loginWithIdentifier(identifier, password) {
  const { data, error } = await supabase.functions.invoke("login-with-identifier", {
    body: { identifier, password },
  });
  if (error) throw error;
  if (data?.error) throw new Error(data.error);

  const { error: sessionError } = await supabase.auth.setSession({
    access_token: data.access_token,
    refresh_token: data.refresh_token,
  });
  if (sessionError) throw sessionError;

  const profile = await verifyActiveSessionOrSignOut();
  return { profile };
}

/** Shared post-sign-in checks for both login() and loginWithIdentifier(). */
async function verifyActiveSessionOrSignOut() {
  const profile = await getMyProfile();
  if (!profile) {
    await supabase.auth.signOut();
    throw new Error("تعذر العثور على ملف المستخدم، تواصل مع الإدارة");
  }
  if (!profile.is_active) {
    await supabase.auth.signOut();
    throw new Error("هذا الحساب معطل، تواصل مع الإدارة");
  }
  // super_admin has no school_id — only school-scoped roles can be blocked
  // by their school's own suspension.
  if (profile.school_id) {
    const { data: school } = await supabase.from("schools").select("is_active").eq("id", profile.school_id).maybeSingle();
    if (school && !school.is_active) {
      await supabase.auth.signOut();
      throw new Error("حساب المدرسة معلّق حالياً، تواصل مع إدارة المنصة");
    }
  }
  return profile;
}

export async function logout() {
  await supabase.auth.signOut();
  window.location.href = "/login.html";
}

/** @returns {Promise<object|null>} */
export async function getMyProfile() {
  const { data: sessionData } = await supabase.auth.getSession();
  const user = sessionData?.session?.user;
  if (!user) return null;
  const { data, error } = await supabase.from("profiles").select("*").eq("id", user.id).single();
  if (error) return null;
  return data;
}

/**
 * Verifies the current session has one of the allowed roles. Redirects to
 * login if there is no session, or to the caller's own dashboard if their
 * role doesn't match. Call this before rendering anything on a guarded page.
 * @param {string[]} allowedRoles
 * @returns {Promise<object>} the caller's profile
 */
export async function requireRole(allowedRoles) {
  const profile = await getMyProfile();
  if (!profile) {
    window.location.href = "/login.html";
    throw new Error("redirecting");
  }
  if (!allowedRoles.includes(profile.role)) {
    window.location.href = ROLE_HOME[profile.role] ?? "/login.html";
    throw new Error("redirecting");
  }
  return profile;
}

export function homeForRole(role) {
  return ROLE_HOME[role] ?? "/login.html";
}

// Keep any open tab in sync if the session ends elsewhere.
supabase.auth.onAuthStateChange((event) => {
  if (event === "SIGNED_OUT" && !window.location.pathname.endsWith("index.html")) {
    window.location.href = "/login.html";
  }
});
