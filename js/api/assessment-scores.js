// School OS — assessment scores API (a student's result on one assessment).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/**
 * Roster for score entry: every active student in the assessment's class,
 * with their existing score (if already graded) merged in.
 * @param {string} assessmentId
 * @param {string} classId
 */
export async function getScoreSheet(assessmentId, classId) {
  try {
    const { data: students, error: studentsError } = await supabase
      .from("students")
      .select("id, full_name, sections!inner(class_id)")
      .eq("sections.class_id", classId)
      .eq("is_active", true)
      .order("full_name");
    if (studentsError) throw studentsError;
    if (!students || students.length === 0) return [];

    const { data: existing, error: scoresError } = await supabase
      .from("assessment_scores")
      .select("student_id, score, is_missing")
      .eq("assessment_id", assessmentId);
    if (scoresError) throw scoresError;

    const byStudent = new Map((existing ?? []).map((r) => [r.student_id, r]));
    return students.map((s) => ({
      student_id: s.id,
      full_name: s.full_name,
      score: byStudent.get(s.id)?.score ?? null,
      is_missing: byStudent.get(s.id)?.is_missing ?? false,
    }));
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** All of one student's individual assessment results, most recent first. */
export async function listStudentScores(studentId) {
  try {
    const { data, error } = await supabase
      .from("assessment_scores")
      .select("*, assessments(title, assessment_date, max_score, subjects(name), assessment_types(name))")
      .eq("student_id", studentId)
      .order("created_at", { ascending: false })
      .limit(30);
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/**
 * @param {{school_id: string, assessment_id: string, graded_by: string, entries: {student_id: string, score: number|null, is_missing: boolean}[]}} payload
 */
export async function bulkSaveScores({ school_id, assessment_id, graded_by, entries }) {
  try {
    const rows = entries.map((e) => ({
      school_id,
      assessment_id,
      student_id: e.student_id,
      score: e.is_missing ? null : e.score,
      is_missing: e.is_missing,
      graded_by,
      graded_at: new Date().toISOString(),
    }));
    const { error } = await supabase.from("assessment_scores").upsert(rows, { onConflict: "assessment_id,student_id" });
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
