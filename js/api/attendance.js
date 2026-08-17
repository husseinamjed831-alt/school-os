// School OS — attendance API.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/**
 * Roster for a section on a given date, with existing attendance status
 * (if already recorded) merged in — the shape teacher/attendance.html needs
 * to render one row per student with a preselected status.
 * @param {string} sectionId
 * @param {string} date  YYYY-MM-DD
 */
export async function getSectionAttendanceForDate(sectionId, date) {
  try {
    const { data: students, error: studentsError } = await supabase
      .from("students")
      .select("id, full_name")
      .eq("section_id", sectionId)
      .eq("is_active", true)
      .order("full_name");
    if (studentsError) throw studentsError;
    if (!students || students.length === 0) return [];

    const studentIds = students.map((s) => s.id);
    const { data: existing, error: attendanceError } = await supabase
      .from("attendance")
      .select("student_id, status, note")
      .eq("date", date)
      .in("student_id", studentIds);
    if (attendanceError) throw attendanceError;

    const byStudent = new Map((existing ?? []).map((r) => [r.student_id, r]));
    return students.map((s) => ({
      student_id: s.id,
      full_name: s.full_name,
      status: byStudent.get(s.id)?.status ?? null,
      note: byStudent.get(s.id)?.note ?? "",
    }));
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/**
 * Upserts one attendance row per student for a single date.
 * @param {{school_id: string, date: string, recorded_by: string, records: {student_id: string, status: string, note?: string}[]}} payload
 */
export async function bulkSaveAttendance({ school_id, date, recorded_by, records }) {
  try {
    const rows = records.map((r) => ({
      school_id,
      student_id: r.student_id,
      date,
      status: r.status,
      note: r.note || null,
      recorded_by,
    }));
    const { error } = await supabase.from("attendance").upsert(rows, { onConflict: "student_id,date" });
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {string} studentId @param {{start?: string, end?: string}} [range] */
export async function listStudentAttendanceHistory(studentId, range = {}) {
  try {
    let query = supabase
      .from("attendance")
      .select("*")
      .eq("student_id", studentId)
      .order("date", { ascending: false });
    if (range.start) query = query.gte("date", range.start);
    if (range.end) query = query.lte("date", range.end);
    const { data, error } = await query.limit(60);
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
