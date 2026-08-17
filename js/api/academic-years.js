// School OS — academic years API.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

export async function listAcademicYears() {
  try {
    const { data, error } = await supabase.from("academic_years").select("*").order("starts_on", { ascending: false });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{label: string, starts_on: string, ends_on: string, school_id: string}} data */
export async function createAcademicYear(data) {
  try {
    const { data: created, error } = await supabase.from("academic_years").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateAcademicYear(id, data) {
  try {
    const { data: updated, error } = await supabase.from("academic_years").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** Marks one academic year current and un-marks all others for the school. */
export async function setCurrentAcademicYear(id, schoolId) {
  try {
    const { error: clearError } = await supabase
      .from("academic_years")
      .update({ is_current: false })
      .eq("school_id", schoolId);
    if (clearError) throw clearError;
    const { error } = await supabase.from("academic_years").update({ is_current: true }).eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
