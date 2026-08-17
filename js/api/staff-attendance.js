// School OS — staff (teacher/admin) attendance API.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** Roster for a given date: every active staff profile in the school, with existing status merged in. */
export async function getStaffAttendanceForDate(date) {
  try {
    const { data: staff, error: staffError } = await supabase
      .from("profiles")
      .select("id, full_name, role")
      .in("role", ["teacher", "branch_admin", "school_admin"])
      .eq("is_active", true)
      .order("full_name");
    if (staffError) throw staffError;
    if (!staff || staff.length === 0) return [];

    const { data: existing, error: attError } = await supabase
      .from("staff_attendance")
      .select("profile_id, status, note")
      .eq("date", date);
    if (attError) throw attError;

    const byProfile = new Map((existing ?? []).map((r) => [r.profile_id, r]));
    return staff.map((s) => ({
      profile_id: s.id,
      full_name: s.full_name,
      role: s.role,
      status: byProfile.get(s.id)?.status ?? null,
      note: byProfile.get(s.id)?.note ?? "",
    }));
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{school_id: string, date: string, recorded_by: string, records: {profile_id: string, status: string, note?: string}[]}} payload */
export async function bulkSaveStaffAttendance({ school_id, date, recorded_by, records }) {
  try {
    const rows = records.map((r) => ({
      school_id,
      profile_id: r.profile_id,
      date,
      status: r.status,
      note: r.note || null,
      recorded_by,
    }));
    const { error } = await supabase.from("staff_attendance").upsert(rows, { onConflict: "profile_id,date" });
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {string} profileId @param {{start?: string, end?: string}} [range] */
export async function listStaffAttendanceHistory(profileId, range = {}) {
  try {
    let query = supabase.from("staff_attendance").select("*").eq("profile_id", profileId).order("date", { ascending: false });
    if (range.start) query = query.gte("date", range.start);
    if (range.end) query = query.lte("date", range.end);
    const { data, error } = await query.limit(60);
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
