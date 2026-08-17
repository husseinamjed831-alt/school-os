// School OS — notifications API.
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

/** @param {string} userId */
export async function listMyNotifications(userId) {
  try {
    const { data, error } = await supabase
      .from("notifications")
      .select("*")
      .eq("user_id", userId)
      .order("created_at", { ascending: false })
      .limit(20);
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

export async function markNotificationRead(id) {
  try {
    const { error } = await supabase.from("notifications").update({ is_read: true }).eq("id", id);
    if (error) throw error;
    return true;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}

/** @param {{school_id: string, user_id: string, title: string, body?: string}} data */
export async function createNotification(data) {
  try {
    const { data: created, error } = await supabase.from("notifications").insert(data).select().single();
    if (error) throw error;
    return created;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
