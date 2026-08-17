// School OS — Telegram account linking (client side: generates a short
// code the user sends to the bot; the bot itself does the actual linking
// via supabase/functions/telegram-webhook, which runs with service_role).
import { supabase } from "../lib/supabase-client.js";
import { toArabicError } from "../lib/utils.js";

function randomCode() {
  return String(Math.floor(100000 + Math.random() * 900000)); // 6 digits
}

/** @returns {Promise<{code: string, expires_at: string}>} */
export async function createTelegramLinkCode() {
  try {
    const { data: sessionData } = await supabase.auth.getSession();
    const uid = sessionData?.session?.user?.id;
    if (!uid) throw new Error("الرجاء تسجيل الدخول أولاً");
    const code = randomCode();
    const { data, error } = await supabase
      .from("telegram_link_codes")
      .insert({ profile_id: uid, code })
      .select("code, expires_at")
      .single();
    if (error) throw error;
    return data;
  } catch (err) {
    throw new Error(toArabicError(err.message));
  }
}
