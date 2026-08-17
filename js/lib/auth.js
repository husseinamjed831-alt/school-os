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
  const profile = await getMyProfile();
  if (!profile) {
    await supabase.auth.signOut();
    throw new Error("تعذر العثور على ملف المستخدم، تواصل مع الإدارة");
  }
  if (!profile.is_active) {
    await supabase.auth.signOut();
    throw new Error("هذا الحساب معطل، تواصل مع الإدارة");
  }
  return { profile, session: data.session };
}

export async function logout() {
  await supabase.auth.signOut();
  window.location.href = "/index.html";
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
    window.location.href = "/index.html";
    throw new Error("redirecting");
  }
  if (!allowedRoles.includes(profile.role)) {
    window.location.href = ROLE_HOME[profile.role] ?? "/index.html";
    throw new Error("redirecting");
  }
  return profile;
}

export function homeForRole(role) {
  return ROLE_HOME[role] ?? "/index.html";
}

// Keep any open tab in sync if the session ends elsewhere.
supabase.auth.onAuthStateChange((event) => {
  if (event === "SIGNED_OUT" && !window.location.pathname.endsWith("index.html")) {
    window.location.href = "/index.html";
  }
});
