-- ============================================================
-- School OS — 008: teacher account activation (HAMURA ID + one-time code)
-- Depends on: 001 (profiles, schools), 003 (audit.log_change())
--
-- Purely additive — no existing row is deleted or overwritten. Every
-- profile that already exists gets a generated hamura_id and keeps
-- activation_status = 'active' (they already have working passwords),
-- so no current user is affected or locked out.
--
-- Design: instead of an admin typing an initial password for a new
-- teacher, create-user now creates the auth account with an unusable
-- random password and issues a one-time activation code (hashed, never
-- stored in plaintext, single use, short expiry). The teacher visits a
-- public /activate.html page with their HAMURA ID + code and picks their
-- own password. See supabase/functions/create-user,
-- reissue-activation-code, activate-account.
-- ============================================================

-- ---------- hamura_id: short, unique, human-shareable account id ----------
create or replace function generate_hamura_id() returns text
language plpgsql as $$
declare
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no 0/O/1/I — avoids misread codes
  candidate text;
  already_used boolean;
begin
  loop
    candidate := 'HM-';
    for i in 1..6 loop
      candidate := candidate || substr(chars, 1 + floor(random() * length(chars))::int, 1);
    end loop;
    select exists(select 1 from profiles where hamura_id = candidate) into already_used;
    exit when not already_used;
  end loop;
  return candidate;
end;
$$;

alter table profiles add column hamura_id text unique;

-- Backfill via an explicit loop (not a bulk UPDATE calling
-- generate_hamura_id() per row) — a single statement's snapshot doesn't
-- see rows it already updated earlier in that same statement, so a bulk
-- UPDATE could theoretically generate the same candidate twice and abort
-- the whole migration on the unique constraint. This loop tracks
-- already-assigned ids in a local variable instead, so it can't collide
-- with itself no matter how many rows exist.
do $$
declare
  r record;
  candidate text;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  used text[] := array(select hamura_id from profiles where hamura_id is not null);
begin
  for r in select id from profiles where hamura_id is null loop
    loop
      candidate := 'HM-';
      for i in 1..6 loop
        candidate := candidate || substr(chars, 1 + floor(random() * length(chars))::int, 1);
      end loop;
      exit when not (candidate = any(used));
    end loop;
    update profiles set hamura_id = candidate where id = r.id;
    used := array_append(used, candidate);
  end loop;
end $$;

alter table profiles alter column hamura_id set not null;
alter table profiles alter column hamura_id set default generate_hamura_id();

-- ---------- activation_status: distinct from is_active (enabled/disabled) ----------
-- Existing accounts already have a working password — they start 'active'.
-- Only newly created teacher accounts start 'pending' (set explicitly by
-- create-user), never as a side effect of this migration.
alter table profiles add column activation_status text not null default 'active'
  check (activation_status in ('pending', 'active'));

-- ---------- one-time activation codes ----------
-- Never exposed to any client role — only Edge Functions (service_role,
-- which bypasses RLS) read or write this table. RLS enabled with zero
-- policies is the same lockdown idiom already used for audit.audit_log.
create table account_activations (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  school_id uuid references schools(id) on delete cascade,
  code_hash text not null,
  attempts int not null default 0,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index account_activations_profile_idx on account_activations(profile_id);

alter table account_activations enable row level security;
-- Deliberately no policies: default-deny for anon/authenticated. Only
-- service_role (Edge Functions), which bypasses RLS, can read or write.

create trigger audit_account_activations after insert or update or delete on account_activations
  for each row execute function audit.log_change();
