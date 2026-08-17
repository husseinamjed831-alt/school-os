// School OS — grading scales API (percent -> label, e.g. "ناجح"/"A").
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

export async function listGradingScales() {
  try {
    const { data, error } = await supabase.from("grading_scales").select("*").order("sort_order");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{label: string, min_percent: number, max_percent: number, color?: string, sort_order?: number, school_id: string}} data */
export async function createGradingScale(data) {
  try {
    const { data: created, error } = await supabase.from("grading_scales").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateGradingScale(id, data) {
  try {
    const { data: updated, error } = await supabase.from("grading_scales").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deleteGradingScale(id) {
  try {
    const { error } = await supabase.from("grading_scales").delete().eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** Maps a weighted percent (0-100) to the matching scale label, if configured. */
export function labelForPercent(scales, percent) {
  if (percent == null || !scales?.length) return null;
  return scales.find((s) => percent >= s.min_percent && percent <= s.max_percent) ?? null;
}
