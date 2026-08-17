// School OS — assessments API (a specific graded event: one quiz, one exam...).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{subjectId?: string}} [filters] */
export async function listAssessments(filters = {}) {
  try {
    let query = supabase
      .from("assessments")
      .select("*, subjects(name), assessment_types(name, weight_percent)")
      .order("assessment_date", { ascending: false });
    if (filters.subjectId) query = query.eq("subject_id", filters.subjectId);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function getAssessment(id) {
  try {
    const { data, error } = await supabase
      .from("assessments")
      .select("*, subjects(name, class_id), assessment_types(name, weight_percent)")
      .eq("id", id)
      .single();
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{title: string, subject_id: string, assessment_type_id: string, max_score: number, assessment_date: string, school_id: string, created_by: string}} data */
export async function createAssessment(data) {
  try {
    const { data: created, error } = await supabase.from("assessments").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateAssessment(id, data) {
  try {
    const { data: updated, error } = await supabase.from("assessments").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteAssessment(id) {
  try {
    const { error } = await supabase.from("assessments").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
