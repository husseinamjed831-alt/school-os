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

    // New day, not yet saved -> every student defaults to "present" (the
    // school marks exceptions, not the common case). A day that was already
    // saved keeps whatever status was actually recorded, including "absent".
    const byStudent = new Map((existing ?? []).map((r) => [r.student_id, r]));
    return students.map((s) => ({
      student_id: s.id,
      full_name: s.full_name,
      status: byStudent.get(s.id)?.status ?? "present",
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

/**
 * Admin/branch-admin daily overview: one row per section showing how many
 * active students are present/absent/late/excused/not-yet-recorded on a
 * given date. Relies entirely on RLS (school_admin sees their school,
 * branch_admin their branch) — no school_id/branch_id filter is trusted
 * from the caller.
 * @param {string} date  YYYY-MM-DD
 * @param {{classId?: string, sectionId?: string}} [filters]
 */
export async function getDailyAttendanceOverview(date, filters = {}) {
  try {
    let studentsQuery = supabase
      .from("students")
      .select("id, section_id, sections(name, classes(id, name, grade_level, branch_id))")
      .eq("is_active", true)
      .not("section_id", "is", null);
    if (filters.sectionId) studentsQuery = studentsQuery.eq("section_id", filters.sectionId);
    if (filters.classId) studentsQuery = studentsQuery.eq("sections.class_id", filters.classId);
    const { data: students, error: studentsError } = await studentsQuery;
    if (studentsError) throw studentsError;
    if (!students || students.length === 0) return [];

    const studentIds = students.map((s) => s.id);
    const { data: attendanceRows, error: attendanceError } = await supabase
      .from("attendance")
      .select("student_id, status")
      .eq("date", date)
      .in("student_id", studentIds);
    if (attendanceError) throw attendanceError;
    const statusByStudent = new Map((attendanceRows ?? []).map((r) => [r.student_id, r.status]));

    const bySection = new Map();
    for (const s of students) {
      // A filtered-out class (via the .eq on the joined table) comes back
      // with sections === null in PostgREST rather than being excluded.
      if (filters.classId && !s.sections) continue;
      const sectionId = s.section_id;
      if (!bySection.has(sectionId)) {
        bySection.set(sectionId, {
          section_id: sectionId,
          section_name: s.sections?.name ?? "—",
          class_name: s.sections?.classes?.name ?? "—",
          grade_level: s.sections?.classes?.grade_level ?? null,
          present: 0,
          absent: 0,
          late: 0,
          excused: 0,
          not_recorded: 0,
          total: 0,
        });
      }
      const row = bySection.get(sectionId);
      row.total += 1;
      const status = statusByStudent.get(s.id);
      if (!status) row.not_recorded += 1;
      else row[status] += 1;
    }

    return [...bySection.values()].sort((a, b) => (a.grade_level ?? 0) - (b.grade_level ?? 0) || a.section_name.localeCompare(a.section_name));
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
