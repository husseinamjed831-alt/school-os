// School OS — fees & payments API.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

export async function listFees() {
  try {
    const { data, error } = await supabase.from("fees").select("*, academic_years(label, is_current)").order("grade_level");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{grade_level: number, academic_year_id: string, annual_amount: number, currency?: string, school_id: string}} data */
export async function createFee(data) {
  try {
    const { data: created, error } = await supabase.from("fees").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateFee(id, data) {
  try {
    const { data: updated, error } = await supabase.from("fees").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteFee(id) {
  try {
    const { error } = await supabase.from("fees").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {string} studentId */
export async function listPayments(studentId) {
  try {
    const { data, error } = await supabase
      .from("payments")
      .select("*, recorded_by_profile:recorded_by(full_name)")
      .eq("student_id", studentId)
      .order("paid_at", { ascending: false });
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{student_id: string, amount: number, paid_at: string, method: string, note?: string, school_id: string, recorded_by: string}} data */
export async function createPayment(data) {
  try {
    const { data: created, error } = await supabase.from("payments").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {string} studentId @returns {Promise<{annual_amount:number, total_paid:number, remaining:number, currency:string}|null>} */
export async function getStudentBalance(studentId) {
  try {
    const { data, error } = await supabase.rpc("fn_student_balance", { p_student_id: studentId });
    if (error) {
      if (error.code === "42501" || error.message?.includes("غير مصرح")) return null;
      throw error;
    }
    return data?.[0] ?? null;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
