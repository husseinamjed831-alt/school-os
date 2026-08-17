// School OS — subjects API (a subject taught within a class, assigned to a teacher).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{classId?: string, teacherId?: string}} [filters] */
export async function listSubjects(filters = {}) {
  try {
    let query = supabase
      .from("subjects")
      .select("*, classes(name, grade_level), teachers(id, profile_id, profiles(full_name))")
      .order("name");
    if (filters.classId) query = query.eq("class_id", filters.classId);
    if (filters.teacherId) query = query.eq("teacher_id", filters.teacherId);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{name: string, class_id: string, teacher_id?: string, school_id: string}} data */
export async function createSubject(data) {
  try {
    const { data: created, error } = await supabase.from("subjects").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateSubject(id, data) {
  try {
    const { data: updated, error } = await supabase.from("subjects").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteSubject(id) {
  try {
    const { error } = await supabase.from("subjects").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** Subjects assigned to the currently logged-in teacher. */
export async function listMySubjects() {
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const uid = sessionData?.session?.user?.id;
    if (!uid) return [];
    const { data: teacherRow, error: teacherError } = await supabase
      .from("teachers")
      .select("id")
      .eq("profile_id", uid)
      .single();
    if (teacherError || !teacherRow) return [];
    const { data, error } = await supabase
      .from("subjects")
      .select("*, classes(id, name, grade_level)")
      .eq("teacher_id", teacherRow.id)
      .order("name");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
