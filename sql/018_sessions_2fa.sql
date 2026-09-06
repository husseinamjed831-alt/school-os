-- ============================================================
-- School OS — 018: sessions / devices / 2FA (V1 Phase 6, migration M6)
-- Depends on: 001 (profiles), 013 (current_school_id), 015 (school_settings),
--   016 (record_security_event).
--
-- 2FA uses Supabase native MFA (auth.mfa_factors + aal2 in the JWT). This
-- migration adds: a session/device registry the app upserts on login and
-- checks on every request (so revocation actually takes effect before the
-- 1h JWT expires), revocation RPCs, and the per-school MFA-enforcement
-- policy. Enforcement itself is applied in the app edge/proxy layer using
-- session_is_active() + the policy row.
--
-- Rollback: sql/018_sessions_2fa_rollback.sql   Tests: sql/tests/018_sessions.sql
-- ============================================================

begin;

create table if not exists public.user_devices (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  fingerprint  text not null,
  label        text,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  trust_state  text not null default 'unrecognized' check (trust_state in ('unrecognized','trusted','blocked')),
  blocked_at   timestamptz,
  blocked_by   uuid references public.profiles(id) on delete set null,
  unique (user_id, fingerprint)
);
create index if not exists user_devices_user_idx on public.user_devices(user_id);

create table if not exists public.user_sessions (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  school_id           uuid references public.schools(id) on delete set null,
  device_id           uuid references public.user_devices(id) on delete set null,
  supabase_session_ref text,                 -- the GoTrue session id / a stable token hash
  ip                  inet,
  user_agent          text,
  created_at          timestamptz not null default now(),
  last_seen_at        timestamptz not null default now(),
  revoked_at          timestamptz,
  revoked_by          uuid references public.profiles(id) on delete set null,
  revoke_reason       text
);
create index if not exists user_sessions_user_active_idx on public.user_sessions(user_id) where revoked_at is null;
create index if not exists user_sessions_ref_idx on public.user_sessions(supabase_session_ref);

alter table public.user_devices  enable row level security;
alter table public.user_sessions enable row level security;

-- self can see own devices/sessions; school_admin can see (+ revoke) those
-- of users in their school; super_admin all.
create policy ud_self  on public.user_devices for select using (user_id = auth.uid());
create policy ud_super on public.user_devices for all using (is_super_admin()) with check (is_super_admin());
create policy ud_admin on public.user_devices for select
  using (my_role() in ('school_admin','branch_admin')
         and user_id in (select id from public.profiles where school_id = current_school_id()));

create policy us_self  on public.user_sessions for select using (user_id = auth.uid());
create policy us_super on public.user_sessions for all using (is_super_admin()) with check (is_super_admin());
create policy us_admin on public.user_sessions for select
  using (my_role() in ('school_admin','branch_admin')
         and user_id in (select id from public.profiles where school_id = current_school_id()));

-- writes only via the SECURITY DEFINER helpers below
revoke insert, update, delete, truncate on public.user_sessions from authenticated, anon;
revoke insert, update, delete, truncate on public.user_devices  from authenticated, anon;

create trigger audit_user_sessions after insert or update or delete on public.user_sessions
  for each row execute function audit.log_change();

-- ------------------------------------------------------------
-- register / touch a session (called by the app on login + heartbeat)
-- ------------------------------------------------------------
create or replace function public.register_session(
  p_session_ref text, p_fingerprint text default null, p_label text default null,
  p_ip inet default null, p_user_agent text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_school uuid := current_school_id();
        v_dev uuid; v_sess uuid; v_new_device boolean := false;
begin
  if v_uid is null then raise exception 'غير مصرح' using errcode='42501'; end if;

  if p_fingerprint is not null then
    select id into v_dev from public.user_devices where user_id = v_uid and fingerprint = p_fingerprint;
    if v_dev is null then
      insert into public.user_devices (user_id, fingerprint, label)
      values (v_uid, p_fingerprint, p_label) returning id into v_dev;
      v_new_device := true;
    else
      update public.user_devices set last_seen_at = now(), label = coalesce(p_label, label) where id = v_dev;
    end if;
  end if;

  select id into v_sess from public.user_sessions
   where user_id = v_uid and supabase_session_ref = p_session_ref and revoked_at is null;
  if v_sess is null then
    insert into public.user_sessions (user_id, school_id, device_id, supabase_session_ref, ip, user_agent)
    values (v_uid, v_school, v_dev, p_session_ref, p_ip, p_user_agent)
    returning id into v_sess;
    perform public.record_security_event('login.success', 'ok',
      jsonb_build_object('new_device', v_new_device, 'session', v_sess), v_uid, v_school);
  else
    update public.user_sessions set last_seen_at = now() where id = v_sess;
  end if;
  return v_sess;
end $$;
revoke execute on function public.register_session(text,text,text,inet,text) from public;
grant  execute on function public.register_session(text,text,text,inet,text) to authenticated;

-- ------------------------------------------------------------
-- is this session still valid? (called by the app proxy on every request)
-- ------------------------------------------------------------
create or replace function public.session_is_active(p_session_ref text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_sessions
    where supabase_session_ref = p_session_ref
      and user_id = auth.uid()
      and revoked_at is null
  )
  -- if the app never registered a session yet (first request after login),
  -- treat as active so we don't lock users out; register_session runs next.
  or not exists (select 1 from public.user_sessions where user_id = auth.uid())
$$;
revoke execute on function public.session_is_active(text) from public;
grant  execute on function public.session_is_active(text) to authenticated;

-- ------------------------------------------------------------
-- revoke
-- ------------------------------------------------------------
create or replace function public.revoke_session(p_session uuid, p_reason text default 'user')
returns void
language plpgsql security definer set search_path = public as $$
declare v public.user_sessions;
begin
  select * into v from public.user_sessions where id = p_session;
  if not found then raise exception 'الجلسة غير موجودة' using errcode='42501'; end if;
  if not (v.user_id = auth.uid() or is_super_admin()
          or (my_role() in ('school_admin','branch_admin')
              and v.user_id in (select id from public.profiles where school_id = current_school_id()))) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  update public.user_sessions set revoked_at = coalesce(revoked_at, now()),
         revoked_by = auth.uid(), revoke_reason = p_reason
   where id = p_session;
  perform public.record_security_event('session.revoked','ok',
    jsonb_build_object('session', p_session, 'reason', p_reason), v.user_id, v.school_id);
  perform public.emit_event('SessionRevoked','session', p_session, jsonb_build_object('user_id', v.user_id));
end $$;
revoke execute on function public.revoke_session(uuid,text) from public;
grant  execute on function public.revoke_session(uuid,text) to authenticated;

create or replace function public.revoke_all_sessions(p_user uuid, p_reason text default 'revoke_all')
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int; v_school uuid;
begin
  select school_id into v_school from public.profiles where id = p_user;
  if not (p_user = auth.uid() or is_super_admin()
          or (my_role() in ('school_admin','branch_admin') and v_school = current_school_id())) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  update public.user_sessions set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = p_reason
   where user_id = p_user and revoked_at is null;
  get diagnostics v_n = row_count;
  perform public.record_security_event('session.revoked_all','ok', jsonb_build_object('count', v_n), p_user, v_school);
  return v_n;
end $$;
revoke execute on function public.revoke_all_sessions(uuid,text) from public;
grant  execute on function public.revoke_all_sessions(uuid,text) to authenticated;

create or replace function public.block_device(p_device uuid, p_block boolean default true)
returns void
language plpgsql security definer set search_path = public as $$
declare v public.user_devices;
begin
  select * into v from public.user_devices where id = p_device;
  if not found then raise exception 'الجهاز غير موجود' using errcode='42501'; end if;
  if not (v.user_id = auth.uid() or is_super_admin()
          or (my_role() in ('school_admin','branch_admin')
              and v.user_id in (select id from public.profiles where school_id = current_school_id()))) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  update public.user_devices
     set trust_state = case when p_block then 'blocked' else 'unrecognized' end,
         blocked_at = case when p_block then now() else null end,
         blocked_by = case when p_block then auth.uid() else null end
   where id = p_device;
  if p_block then
    update public.user_sessions set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = 'device blocked'
     where device_id = p_device and revoked_at is null;
    perform public.record_security_event('device.blocked','ok', jsonb_build_object('device', p_device), v.user_id, null);
  end if;
end $$;
revoke execute on function public.block_device(uuid,boolean) from public;
grant  execute on function public.block_device(uuid,boolean) to authenticated;

-- ------------------------------------------------------------
-- MFA enforcement policy per school (native Supabase MFA does the TOTP)
-- ------------------------------------------------------------
alter table public.school_settings
  add column if not exists mfa_required_roles text[] not null default '{}'::text[];

-- helper the app proxy uses: does this caller's role require MFA at this school?
create or replace function public.mfa_required_for_me()
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select my_role() = any(ss.mfa_required_roles)
       from public.school_settings ss where ss.school_id = current_school_id()),
    false)
$$;
revoke execute on function public.mfa_required_for_me() from public;
grant  execute on function public.mfa_required_for_me() to authenticated;

commit;
