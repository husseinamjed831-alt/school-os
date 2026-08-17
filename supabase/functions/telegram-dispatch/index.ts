// School OS — Telegram notification dispatch.
//
// Called every minute by a pg_cron job (see sql/008_telegram.sql). Sends
// any `notifications` row with sent_to_telegram = false to its user's
// linked Telegram chat, then marks it sent. Rows for users with no
// telegram_chat_id are left alone (they'll still see them in the in-app
// bell) rather than marked sent — marking them here would silently hide
// them from a future export/report that expects sent_to_telegram=true to
// mean "actually delivered".
//
// Deploy: supabase functions deploy telegram-dispatch --no-verify-jwt
// Secrets required: TELEGRAM_BOT_TOKEN (same as telegram-webhook).
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.

import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  try {
    const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!botToken || !supabaseUrl || !serviceRoleKey) {
      return json({ error: "server not configured" }, 500);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: pending, error } = await admin
      .from("notifications")
      .select("id, title, body, profiles!inner(telegram_chat_id)")
      .eq("sent_to_telegram", false)
      .not("profiles.telegram_chat_id", "is", null)
      .limit(50);

    if (error) throw error;
    if (!pending || pending.length === 0) {
      return json({ sent: 0 });
    }

    let sent = 0;
    for (const n of pending) {
      const chatId = (n as any).profiles?.telegram_chat_id;
      if (!chatId) continue;
      const text = `🔔 ${n.title}${n.body ? "\n" + n.body : ""}`;
      const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: chatId, text }),
      });
      if (res.ok) {
        await admin.from("notifications").update({ sent_to_telegram: true }).eq("id", n.id);
        sent++;
      }
    }

    return json({ sent, checked: pending.length });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
