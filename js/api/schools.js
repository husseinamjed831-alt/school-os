// School OS — schools API (super_admin: onboarding new tenants).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{search?: string}} [filters] */
export async function listSchools(filters = {}) {
  try {
    let query = supabase.from("schools").select("*").order("created_at", { ascending: false });
    if (filters.search) query = query.ilike("name", `%${filters.search}%`);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function getSchool(id) {
  try {
    const { data, error } = await supabase.from("schools").select("*").eq("id", id).single();
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{name: string, slug: string, logo_url?: string}} data */
export async function createSchool(data) {
  try {
    const { data: created, error } = await supabase.from("schools").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateSchool(id, data) {
  try {
    const { data: updated, error } = await supabase.from("schools").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deactivateSchool(id) {
  try {
    const { error } = await supabase.from("schools").update({ is_active: false, subscription_status: "suspended" }).eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** Re-enables a suspended school — does not touch or restore any of its data. */
export async function activateSchool(id) {
  try {
    const { error } = await supabase.from("schools").update({ is_active: true, subscription_status: "active" }).eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
