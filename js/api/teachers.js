// School OS — teachers API (the `teachers` table row, distinct from the
// `profiles` row — subjects.teacher_id points here, not at a profile id).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

export async function listTeachers() {
  try {
    const { data, error } = await supabase
      .from("teachers")
      .select("id, profile_id, specialty, profiles(full_name, phone, is_active)")
      .order("id");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateTeacherSpecialty(id, specialty) {
  try {
    const { data, error } = await supabase.from("teachers").update({ specialty }).eq("id", id).select().single();
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
