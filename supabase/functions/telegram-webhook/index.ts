// School OS — Telegram bot webhook.
//
// Receives Telegram Update objects, handles account linking and the four
// query commands from the original spec (/درجاتي /غياباتي /جدولي /المتبقي).
// Runs with service_role (needed to look up a profile by telegram_chat_id
// before we know who's talking), so it does its OWN authorization instead
// of relying on the RLS-dependent SQL functions in 007 — those check
// auth.uid(), which is null for a service_role caller by design.
//
// Deploy: supabase functions deploy telegram-webhook --no-verify-jwt
// Secrets required (set via `supabase secrets set`):
//   TELEGRAM_BOT_TOKEN        from @BotFather
//   TELEGRAM_WEBHOOK_SECRET   any random string you choose — must match
//                             the secret_token given to setWebhook, so
//                             only real Telegram calls reach this function
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-telegram-bot-api-secret-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  try {
    const webhookSecret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
    const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!webhookSecret || !botToken || !supabaseUrl || !serviceRoleKey) {
      return json({ error: "server not configured" }, 500);
    }

    const gotSecret = req.headers.get("x-telegram-bot-api-secret-token");
    if (gotSecret !== webhookSecret) {
      return json({ error: "unauthorized" }, 401);
    }

    const update = await req.json().catch(() => null);
    const message = update?.message;
    if (!message?.text || !message?.chat?.id) {
      return json({ ok: true }); // ignore non-text updates (edits, etc.)
    }

    const chatId: number = message.chat.id;
    const text: string = message.text.trim();
    const admin = createClient(supabaseUrl, serviceRoleKey);

    await handleMessage(admin, chatId, text, botToken);
    return json({ ok: true });
  } catch (err) {
    console.error(err);
    return json({ ok: true }); // always 200 to Telegram — it retries on non-2xx
  }
});

async function handleMessage(admin: any, chatId: number, text: string, botToken: string) {
  const { data: profile } = await admin.from("profiles").select("*").eq("telegram_chat_id", chatId).maybeSingle();

  if (text === "/start") {
    await reply(botToken, chatId, profile
      ? `أهلاً ${profile.full_name} 👋\nحسابك مربوط. استخدم:\n/درجاتي\n/غياباتي\n/جدولي\n/المتبقي`
      : `أهلاً بك في بوت School OS 👋\nلربط حسابك: افتح التطبيق، اضغط "ربط تلغرام"، انسخ الكود، وأرسله هنا بهذا الشكل:\n/ربط 123456`);
    return;
  }

  if (text.startsWith("/ربط") || text.startsWith("/link")) {
    const code = text.split(/\s+/)[1]?.trim();
    if (!code) {
      await reply(botToken, chatId, "الرجاء إرسال الكود بهذا الشكل: /ربط 123456");
      return;
    }
    const { data: linkRow } = await admin
      .from("telegram_link_codes")
      .select("*")
      .eq("code", code)
      .is("used_at", null)
      .gt("expires_at", new Date().toISOString())
      .maybeSingle();
    if (!linkRow) {
      await reply(botToken, chatId, "الكود غير صحيح أو منتهي الصلاحية. أنشئ كوداً جديداً من التطبيق وحاول مجدداً.");
      return;
    }
    await admin.from("profiles").update({ telegram_chat_id: chatId }).eq("id", linkRow.profile_id);
    await admin.from("telegram_link_codes").update({ used_at: new Date().toISOString() }).eq("id", linkRow.id);
    const { data: linkedProfile } = await admin.from("profiles").select("full_name").eq("id", linkRow.profile_id).single();
    await reply(botToken, chatId, `تم ربط حسابك بنجاح ✅\nمرحباً ${linkedProfile?.full_name ?? ""}`);
    return;
  }

  if (!profile) {
    await reply(botToken, chatId, "حسابك غير مربوط بعد. أرسل /start للتعليمات.");
    return;
  }

  const student = await resolveStudentForProfile(admin, profile);

  if (text === "/درجاتي") {
    if (!student) return reply(botToken, chatId, studentOnlyMessage(profile.role));
    await reply(botToken, chatId, await formatGrades(admin, student));
    return;
  }
  if (text === "/غياباتي") {
    if (!student) return reply(botToken, chatId, studentOnlyMessage(profile.role));
    await reply(botToken, chatId, await formatAttendance(admin, student));
    return;
  }
  if (text === "/جدولي") {
    if (!student) return reply(botToken, chatId, studentOnlyMessage(profile.role));
    await reply(botToken, chatId, await formatSchedule(admin, student));
    return;
  }
  if (text === "/المتبقي") {
    await reply(botToken, chatId, "نظام المدفوعات غير مفعّل بعد بهذا الإصدار من النظام.");
    return;
  }

  await reply(botToken, chatId, "أمر غير معروف. الأوامر المتاحة:\n/درجاتي\n/غياباتي\n/جدولي\n/المتبقي");
}

function studentOnlyMessage(role: string) {
  if (role === "parent") return "هذا الأمر يعرض بيانات طالب واحد — حالياً هذه الميزة مفعّلة فقط عند ربط ولي الأمر بابن واحد. تواصل مع إدارة المدرسة.";
  return "هذا الأمر متاح فقط لحسابات الطلاب حالياً.";
}

/** Students see their own record; a parent linked to exactly one child sees that child's. */
async function resolveStudentForProfile(admin: any, profile: any) {
  if (profile.role === "student") {
    const { data } = await admin.from("students").select("id, full_name, section_id").eq("profile_id", profile.id).maybeSingle();
    return data ?? null;
  }
  if (profile.role === "parent") {
    const { data } = await admin.from("students").select("id, full_name, section_id").eq("parent_id", profile.id);
    return data && data.length === 1 ? data[0] : null;
  }
  return null;
}

async function formatAttendance(admin: any, student: any) {
  const ninetyDaysAgo = new Date(Date.now() - 90 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const { data } = await admin.from("attendance").select("status").eq("student_id", student.id).gte("date", ninetyDaysAgo);
  if (!data || data.length === 0) return `${student.full_name}: لا يوجد سجل حضور بعد.`;
  const present = data.filter((r: any) => r.status === "present" || r.status === "late").length;
  const rate = Math.round((100 * present) / data.length);
  return `📅 حضور ${student.full_name}\nنسبة الحضور (آخر 90 يوم): ${rate}%\nعدد الأيام المسجّلة: ${data.length}`;
}

async function formatGrades(admin: any, student: any) {
  const { data } = await admin
    .from("assessment_scores")
    .select("score, is_missing, assessments(max_score, subjects(name), assessment_types(weight_percent))")
    .eq("student_id", student.id);
  if (!data || data.length === 0) return `${student.full_name}: لا توجد درجات مسجّلة بعد.`;

  const bySubject = new Map<string, { earned: number; total: number }>();
  for (const row of data) {
    if (row.score == null) continue;
    const subjectName = row.assessments?.subjects?.name ?? "—";
    const weight = row.assessments?.assessment_types?.weight_percent ?? 0;
    const maxScore = row.assessments?.max_score ?? 100;
    const entry = bySubject.get(subjectName) ?? { earned: 0, total: 0 };
    entry.earned += (row.score / maxScore) * weight;
    entry.total += weight;
    bySubject.set(subjectName, entry);
  }
  if (bySubject.size === 0) return `${student.full_name}: لا توجد درجات مُقيَّمة بعد.`;
  const lines = [...bySubject.entries()].map(
    ([name, { earned, total }]) => `${name}: ${total > 0 ? Math.round((100 * earned) / total) + "%" : "—"}`
  );
  return `📊 درجات ${student.full_name}\n${lines.join("\n")}`;
}

async function formatSchedule(admin: any, student: any) {
  if (!student.section_id) return `${student.full_name}: لم يُحدَّد الصف بعد.`;
  const today = new Date().getDay();
  const { data } = await admin
    .from("schedule")
    .select("period, subjects(name)")
    .eq("section_id", student.section_id)
    .eq("day", today)
    .order("period");
  if (!data || data.length === 0) return `${student.full_name}: لا توجد حصص مجدولة اليوم.`;
  const lines = data.map((s: any) => `الحصة ${s.period}: ${s.subjects?.name ?? "—"}`);
  return `🗓️ جدول ${student.full_name} اليوم\n${lines.join("\n")}`;
}

async function reply(botToken: string, chatId: number, text: string) {
  await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS_HEADERS } });
}
