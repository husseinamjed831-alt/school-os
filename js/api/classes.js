// School OS — classes API (grade-level groupings within a branch/year).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{branchId?: string, academicYearId?: string}} [filters] */
export async function listClasses(filters = {}) {
  try {
    let query = supabase.from("classes").select("*, branches(name), academic_years(label)").order("grade_level");
    if (filters.branchId) query = query.eq("branch_id", filters.branchId);
    if (filters.academicYearId) query = query.eq("academic_year_id", filters.academicYearId);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function getClass(id) {
  try {
    const { data, error } = await supabase.from("classes").select("*").eq("id", id).single();
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{name: string, grade_level: number, school_id: string, branch_id: string, academic_year_id: string}} data */
export async function createClass(data) {
  try {
    const { data: created, error } = await supabase.from("classes").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateClass(id, data) {
  try {
    const { data: updated, error } = await supabase.from("classes").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteClass(id) {
  try {
    const { error } = await supabase.from("classes").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
