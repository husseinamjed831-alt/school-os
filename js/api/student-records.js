// School OS — behavior records + teacher notes (Student 360 inputs).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

export async function listBehaviorRecords(studentId) {
  try {
    const { data, error } = await supabase
      .from("behavior_records")
      .select("*, recorded_by_profile:recorded_by(full_name)")
      .eq("student_id", studentId)
      .order("created_at", { ascending: false });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{student_id: string, category: "positive"|"concern", note: string, school_id: string, recorded_by: string}} data */
export async function createBehaviorRecord(data) {
  try {
    const { data: created, error } = await supabase.from("behavior_records").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function listTeacherNotes(studentId) {
  try {
    const { data, error } = await supabase
      .from("teacher_notes")
      .select("*, created_by_profile:created_by(full_name), subjects(name)")
      .eq("student_id", studentId)
      .order("created_at", { ascending: false });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{student_id: string, subject_id?: string, note: string, is_visible_to_parent: boolean, school_id: string, created_by: string}} data */
export async function createTeacherNote(data) {
  try {
    const { data: created, error } = await supabase.from("teacher_notes").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
