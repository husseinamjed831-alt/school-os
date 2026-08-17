// School OS — sections API (the actual class a student sits in).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{classId?: string}} [filters] */
export async function listSections(filters = {}) {
  try {
    let query = supabase.from("sections").select("*, classes(name, grade_level, branch_id)").order("name");
    if (filters.classId) query = query.eq("class_id", filters.classId);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{name: string, class_id: string, school_id: string, capacity?: number}} data */
export async function createSection(data) {
  try {
    const { data: created, error } = await supabase.from("sections").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateSection(id, data) {
  try {
    const { data: updated, error } = await supabase.from("sections").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteSection(id) {
  try {
    const { error } = await supabase.from("sections").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
