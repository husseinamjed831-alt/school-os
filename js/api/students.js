// School OS — students API.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{sectionId?: string, search?: string, includeInactive?: boolean}} [filters] */
export async function listStudents(filters = {}) {
  try {
    let query = supabase
      .from("students")
      .select("*, sections(name, classes(name, grade_level)), parent:parent_id(full_name, phone)")
      .order("full_name");
    if (!filters.includeInactive) query = query.eq("is_active", true);
    if (filters.sectionId) query = query.eq("section_id", filters.sectionId);
    if (filters.search) query = query.ilike("full_name", `%${filters.search}%`);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function getStudent(id) {
  try {
    const { data, error } = await supabase
      .from("students")
      .select("*, sections(name, classes(name, grade_level)), parent:parent_id(full_name, phone)")
      .eq("id", id)
      .single();
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{full_name: string, birth_date?: string, section_id?: string, parent_id?: string, school_id: string, branch_id: string}} data */
export async function createStudent(data) {
  try {
    const { data: created, error } = await supabase.from("students").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateStudent(id, data) {
  try {
    const { data: updated, error } = await supabase.from("students").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** The student row linked to the currently logged-in student account. */
export async function getMyStudentRecord() {
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const uid = sessionData?.session?.user?.id;
    if (!uid) return null;
    const { data, error } = await supabase.from("students").select("id, full_name").eq("profile_id", uid).single();
    if (error) return null;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** Soft delete: is_active=false. */
export async function deactivateStudent(id) {
  try {
    const { error } = await supabase.from("students").update({ is_active: false }).eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
