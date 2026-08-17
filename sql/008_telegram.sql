-- ============================================================
-- School OS — 008: Telegram bot linking + notification dispatch
-- Depends on: 001 (profiles.telegram_chat_id, notifications table already
--   exist from Phase 1), 002 (my_role() not used here, but same helper
--   pattern), 003 (audit.log_change() — not attached here, link codes
--   aren't sensitive enough to warrant an audit trail)
--
-- Design: a logged-in user generates a short-lived code from the app
-- (client-side insert, RLS-guarded to their own profile_id). They send
-- "/ربط <code>" to the bot; the telegram-webhook Edge Function (using
-- service_role, so RLS doesn't apply to it) looks up the code and sets
-- profiles.telegram_chat_id. A pg_cron job calls the telegram-dispatch
-- Edge Function every minute to send any notifications rows still marked
-- sent_to_telegram = false.
-- ============================================================

create table telegram_link_codes (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  code text not null unique,
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index telegram_link_codes_code_idx on telegram_link_codes(code);

alter table telegram_link_codes enable row level security;

-- A user can create and read their own codes (to display it in the UI).
-- No update/delete policy for authenticated users — only the webhook
-- (service_role, bypasses RLS) marks a code used.
create policy own_link_codes_insert on telegram_link_codes for insert
  with check (profile_id = auth.uid());
create policy own_link_codes_select on telegram_link_codes for select
  using (profile_id = auth.uid());

-- ============================================================
-- Scheduled dispatch: pg_cron calling the telegram-dispatch Edge Function
-- every minute via pg_net. Both extensions are standard on every Supabase
-- project, including the free tier.
-- ============================================================
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- Replaced below (after the URL/key are known) via cron.schedule with the
-- same job name — cron.schedule() upserts by name, so re-running this is
-- safe. The project URL is not secret; the anon key is designed to be
-- public and is still RLS-scoped even here (though telegram-dispatch runs
-- as service_role internally regardless of what's in this header — the
-- header is only what the *cron caller* presents to the function, which
-- checks it against DISPATCH_SECRET, not this key).
select cron.schedule(
  'telegram-dispatch-job',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://iabjbaaiumfahjdazvfd.supabase.co/functions/v1/telegram-dispatch',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb
  );
  $$
);
