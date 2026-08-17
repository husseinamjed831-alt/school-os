// School OS — weekly schedule API (day/period timetable per section).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {{sectionId?: string}} [filters] */
export async function listSchedule(filters = {}) {
  try {
    let query = supabase
      .from("schedule")
      .select("*, subjects(name, teachers(profiles(full_name))), sections(name, classes(name))")
      .order("day")
      .order("period");
    if (filters.sectionId) query = query.eq("section_id", filters.sectionId);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/**
 * Creates one schedule slot after checking the assigned subject's teacher
 * isn't already booked in a DIFFERENT section at the same day/period — the
 * unique(section_id, day, period) constraint alone only stops double-booking
 * the same section, not double-booking a teacher across sections.
 * @param {{school_id: string, section_id: string, subject_id: string, day: number, period: number}} data
 */
export async function createScheduleEntry(data) {
  try {
    const { data: subject, error: subjectError } = await supabase
      .from("subjects")
      .select("teacher_id")
      .eq("id", data.subject_id)
      .single();
    if (subjectError) throw subjectError;

    if (subject.teacher_id) {
      const { data: conflicts, error: conflictError } = await supabase
        .from("schedule")
        .select("id, sections(name, classes(name)), subjects!inner(teacher_id)")
        .eq("day", data.day)
        .eq("period", data.period)
        .eq("subjects.teacher_id", subject.teacher_id)
        .neq("section_id", data.section_id);
      if (conflictError) throw conflictError;
      if (conflicts && conflicts.length > 0) {
        const c = conflicts[0];
        throw new Error(`تعارض: هذا المعلم مسجّل بنفس الوقت في ${c.sections?.classes?.name ?? ""} - ${c.sections?.name ?? ""}`);
      }
    }

    const { data: created, error } = await supabase.from("schedule").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteScheduleEntry(id) {
  try {
    const { error } = await supabase.from("schedule").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** Today's schedule slots for the currently logged-in teacher. */
export async function listMyTeachingToday() {
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const uid = sessionData?.session?.user?.id;
    if (!uid) return [];
    const { data: teacherRow } = await supabase.from("teachers").select("id").eq("profile_id", uid).single();
    if (!teacherRow) return [];
    const today = new Date().getDay(); // JS: 0=Sunday, matches schedule.day's 0=الأحد convention
    const { data, error } = await supabase
      .from("schedule")
      .select("*, subjects!inner(name, teacher_id), sections(name, classes(name))")
      .eq("day", today)
      .eq("subjects.teacher_id", teacherRow.id)
      .order("period");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** Today's schedule slots for the currently logged-in student's section. */
export async function listMyScheduleToday() {
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const uid = sessionData?.session?.user?.id;
    if (!uid) return [];
    const { data: studentRow } = await supabase.from("students").select("section_id").eq("profile_id", uid).single();
    if (!studentRow?.section_id) return [];
    const today = new Date().getDay();
    const { data, error } = await supabase
      .from("schedule")
      .select("*, subjects(name, teachers(profiles(full_name)))")
      .eq("section_id", studentRow.section_id)
      .eq("day", today)
      .order("period");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
