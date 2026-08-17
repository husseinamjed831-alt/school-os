// School OS — user accounts API. Creation is proxied through the
// create-user Edge Function because it needs the service_role key, which
// must never be present in browser code.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{role?: string, search?: string}} [filters] */
export async function listUsers(filters = {}) {
  try {
    let query = supabase.from("profiles").select("*").order("full_name");
    if (filters.role) query = query.eq("role", filters.role);
    if (filters.search) query = query.ilike("full_name", `%${filters.search}%`);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/**
 * Creates a login account (teacher / branch_admin / parent / student) via
 * the create-user Edge Function.
 * @param {{email: string, password: string, full_name: string, role: string, branch_id?: string, phone?: string}} data
 */
export async function createUserAccount(data) {
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const token = sessionData?.session?.access_token;
    if (!token) throw new Error("انتهت الجلسة، سجل الدخول مجدداً");

    const { data: fnData, error } = await supabase.functions.invoke("create-user", {
      body: data,
      headers: { Authorization: `Bearer ${token}` },
    });
    if (error) throw error;
    if (fnData?.error) throw new Error(fnData.error);
    return fnData;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deactivateUser(id) {
  try {
    const { error } = await supabase.from("profiles").update({ is_active: false }).eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
