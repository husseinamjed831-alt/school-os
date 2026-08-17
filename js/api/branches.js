// School OS — branches API.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

export async function listBranches() {
  try {
    const { data, error } = await supabase.from("branches").select("*").order("name");
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function getBranch(id) {
  try {
    const { data, error } = await supabase.from("branches").select("*").eq("id", id).single();
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{name: string, address?: string, school_id: string}} data */
export async function createBranch(data) {
  try {
    const { data: created, error } = await supabase.from("branches").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function updateBranch(id, data) {
  try {
    const { data: updated, error } = await supabase.from("branches").update(data).eq("id", id).select().single();
    if (error) throw error;
    return updated;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function deactivateBranch(id) {
  try {
    const { error } = await supabase.from("branches").update({ is_active: false }).eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
