// School OS — assessment types API (school-configurable weighting).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

export async function listAssessmentTypes() {
  try {
    const { data, error } = await supabase.from("assessment_types").select("*").order("sort_order");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{name: string, weight_percent: number, grade_level?: number, sort_order?: number, school_id: string}} data */
export async function createAssessmentType(data) {
  try {
    const { data: created, error } = await supabase.from("assessment_types").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateAssessmentType(id, data) {
  try {
    const { data: updated, error } = await supabase.from("assessment_types").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteAssessmentType(id) {
  try {
    const { error } = await supabase.from("assessment_types").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
