// School OS — deterministic analytics + risk engine (calls the SQL
// functions in sql/007_analytics_functions.sql via RPC). No AI involved —
// every number here is a plain, explainable aggregation.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {string} studentId @param {{start?: string, end?: string}} [range] */
export async function getStudentAttendanceRate(studentId, range = {}) {
  try {
    const { data, error } = await supabase.rpc("fn_student_attendance_rate", {
      p_student_id: studentId,
      p_start: range.start ?? null,
      p_end: range.end ?? null,
    });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {string} sectionId @param {string} [date] */
export async function getSectionAttendanceRate(sectionId, date) {
  try {
    const { data, error } = await supabase.rpc("fn_section_attendance_rate", {
      p_section_id: sectionId,
      p_date: date ?? new Date().toISOString().slice(0, 10),
    });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {string} studentId @returns {Promise<{subject_id:string, subject_name:string, weighted_percent:number|null, assessments_count:number, missing_count:number}[]>} */
export async function getStudentGradeSummary(studentId) {
  try {
    const { data, error } = await supabase.rpc("fn_student_grade_summary", { p_student_id: studentId });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {string} sectionId @param {string} subjectId */
export async function getSectionGradeSummary(sectionId, subjectId) {
  try {
    const { data, error } = await supabase.rpc("fn_section_grade_summary", {
      p_section_id: sectionId,
      p_subject_id: subjectId,
    });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function getStudentMissingAssignmentsCount(studentId) {
  try {
    const { data, error } = await supabase.rpc("fn_student_missing_assignments_count", { p_student_id: studentId });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/**
 * Staff-only. Returns null (not an error toast) if the caller isn't
 * permitted to view it — student/parent dashboards should never call this.
 * @param {string} studentId
 * @returns {Promise<{risk_score:number, risk_level:"low"|"medium"|"high", risk_factors:string[]}|null>}
 */
export async function getStudentRiskScore(studentId) {
  try {
    const { data, error } = await supabase.rpc("fn_student_risk_score", { p_student_id: studentId });
    if (error) {
      if (error.message?.includes("غير مصرح") || error.code === "42501") return null;
      throw error;
    }
    return data?.[0] ?? null;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
