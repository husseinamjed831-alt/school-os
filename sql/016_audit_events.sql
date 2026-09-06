-- ============================================================
-- School OS — 016: audit & events foundation (V1 Phase 4, migration M4)
-- Depends on: 001 (pgcrypto), 002 (my_role/current via 013), 003
--   (audit.audit_log, audit.log_change), 013 (current_school_id),
--   014 (has_perm — not required but present).
--
-- Three distinct record types (HAMURA_EVENT_ARCHITECTURE.md):
--   audit.audit_log  — mechanical DML capture (exists; hardened + full coverage)
--   audit_events     — semantic, actor-attributed, hash-chained, append-only
--   domain_events    — transactional outbox for async consumers
--   security_events  — auth/session/permission events for alerting
-- All four: no client UPDATE/DELETE, enforced by REVOKE + a raise trigger
-- that fires even for service_role.
--
-- Rollback: sql/016_audit_events_rollback.sql   Tests: sql/tests/016_audit.sql
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Harden + extend audit.audit_log
-- ------------------------------------------------------------
alter table audit.audit_log add column if not exists request_id     uuid;
alter table audit.audit_log add column if not exists actor_role      text;
alter table audit.audit_log add column if not exists impersonated_by uuid;

-- enrich the DML capture with request/session context (set by the app via
-- SET LOCAL hamura.request_id / hamura.impersonated_by; NULL when absent).
create or replace function audit.log_change() returns trigger
language plpgsql security definer set search_path = public, audit as $$
declare
  v_school_id uuid;
  v_row_id text;
begin
  v_school_id := case when TG_OP = 'DELETE' then (to_jsonb(old)->>'school_id')::uuid
                      else (to_jsonb(new)->>'school_id')::uuid end;
  v_row_id := case when TG_OP = 'DELETE' then (to_jsonb(old)->>'id')
                   else (to_jsonb(new)->>'id') end;

  insert into audit.audit_log
    (school_id, table_name, row_id, action, actor, actor_role, impersonated_by, request_id, old_data, new_data)
  values (
    v_school_id, TG_TABLE_NAME, v_row_id, TG_OP,
    auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    nullif(current_setting('hamura.impersonated_by', true), '')::uuid,
    nullif(current_setting('hamura.request_id', true), '')::uuid,
    case when TG_OP in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when TG_OP in ('UPDATE','INSERT') then to_jsonb(new) else null end
  );
  return coalesce(new, old);
end;
$$;

-- append-only enforcement (fires for EVERY role, incl. service_role)
create or replace function audit.deny_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'سجل التدقيق للإضافة فقط (append-only)' using errcode = '2F004';
end $$;

drop trigger if exists audit_log_immutable on audit.audit_log;
create trigger audit_log_immutable before update or delete on audit.audit_log
  for each row execute function audit.deny_mutation();

revoke insert, update, delete, truncate on audit.audit_log from authenticated, anon;

-- full coverage: attach the DML trigger to every remaining tenant table
do $$
declare r record;
begin
  for r in
    select c.table_name
    from information_schema.columns c
    join information_schema.tables t on t.table_schema=c.table_schema and t.table_name=c.table_name
    where c.table_schema='public' and c.column_name='school_id' and t.table_type='BASE TABLE'
      and not exists (
        select 1 from information_schema.triggers tg
        where tg.trigger_schema='public' and tg.event_object_table=c.table_name
          and tg.action_statement ilike '%audit.log_change%')
  loop
    execute format('create trigger audit_%s after insert or update or delete on public.%I for each row execute function audit.log_change()', r.table_name, r.table_name);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 2. audit_events — semantic, hash-chained, append-only
-- ------------------------------------------------------------
create table if not exists public.audit_events (
  id              bigint generated always as identity primary key,
  occurred_at     timestamptz not null default now(),
  school_id       uuid,                       -- null = platform action
  actor_user      uuid,
  actor_role      text,
  impersonated_by uuid,
  action          text not null,              -- verb catalogue, e.g. 'grade.published'
  resource_type   text,
  resource_id     uuid,
  before          jsonb,
  after           jsonb,
  ip              inet,
  user_agent      text,
  request_id      uuid,
  prev_hash       bytea,
  row_hash        bytea not null
);
create index if not exists audit_events_school_idx   on public.audit_events(school_id, occurred_at);
create index if not exists audit_events_actor_idx    on public.audit_events(actor_user, occurred_at);
create index if not exists audit_events_action_idx   on public.audit_events(action, occurred_at);
create index if not exists audit_events_resource_idx on public.audit_events(resource_type, resource_id);

alter table public.audit_events enable row level security;
create policy ae_super on public.audit_events for select using (is_super_admin());
create policy ae_admin on public.audit_events for select
  using (school_id = current_school_id()
         and my_role() in ('school_admin','branch_admin')  -- academic/finance managers mirror to school_admin
        );
revoke insert, update, delete, truncate on public.audit_events from authenticated, anon;

create or replace function public.audit_events_chain() returns trigger
language plpgsql as $$
declare
  v_key  text := coalesce(new.school_id::text, 'PLATFORM');
  v_prev bytea;
  v_canon text;
begin
  select row_hash into v_prev from public.audit_events
   where coalesce(school_id::text,'PLATFORM') = v_key
   order by id desc limit 1;

  new.prev_hash := v_prev;
  v_canon := coalesce(new.occurred_at::text,'') || '|' || coalesce(new.school_id::text,'') || '|' ||
             coalesce(new.actor_user::text,'') || '|' || coalesce(new.action,'') || '|' ||
             coalesce(new.resource_type,'') || '|' || coalesce(new.resource_id::text,'') || '|' ||
             coalesce(new.before::text,'') || '|' || coalesce(new.after::text,'');
  new.row_hash := extensions.digest(coalesce(v_prev, ''::bytea) || convert_to(v_canon, 'utf8'), 'sha256');
  return new;
end $$;
create trigger audit_events_chain_ins before insert on public.audit_events
  for each row execute function public.audit_events_chain();

drop trigger if exists audit_events_immutable on public.audit_events;
create trigger audit_events_immutable before update or delete on public.audit_events
  for each row execute function audit.deny_mutation();

-- the sanctioned writer
create or replace function public.record_audit_event(
  p_action text, p_resource_type text default null, p_resource_id uuid default null,
  p_before jsonb default null, p_after jsonb default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  insert into public.audit_events
    (school_id, actor_user, actor_role, impersonated_by, action, resource_type, resource_id, before, after, request_id, row_hash)
  values (
    current_school_id(), auth.uid(), my_role(),
    nullif(current_setting('hamura.impersonated_by', true), '')::uuid,
    p_action, p_resource_type, p_resource_id, p_before, p_after,
    nullif(current_setting('hamura.request_id', true), '')::uuid,
    ''::bytea)                       -- real hash set by the BEFORE trigger
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.record_audit_event(text,text,uuid,jsonb,jsonb) from public;
grant  execute on function public.record_audit_event(text,text,uuid,jsonb,jsonb) to authenticated, service_role;

-- chain verification (returns the first broken id, or NULL if intact)
create or replace function public.verify_audit_chain(p_school uuid default null)
returns bigint
language plpgsql stable security definer set search_path = public as $$
declare r record; v_prev bytea := null; v_calc bytea; v_canon text; v_key text := coalesce(p_school::text,'PLATFORM');
begin
  if auth.uid() is not null and not is_super_admin() then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  for r in
    select * from public.audit_events
     where coalesce(school_id::text,'PLATFORM') = v_key order by id asc
  loop
    v_canon := coalesce(r.occurred_at::text,'') || '|' || coalesce(r.school_id::text,'') || '|' ||
               coalesce(r.actor_user::text,'') || '|' || coalesce(r.action,'') || '|' ||
               coalesce(r.resource_type,'') || '|' || coalesce(r.resource_id::text,'') || '|' ||
               coalesce(r.before::text,'') || '|' || coalesce(r.after::text,'');
    v_calc := extensions.digest(coalesce(v_prev, ''::bytea) || convert_to(v_canon,'utf8'), 'sha256');
    if r.row_hash is distinct from v_calc or r.prev_hash is distinct from v_prev then
      return r.id;
    end if;
    v_prev := r.row_hash;
  end loop;
  return null;
end $$;
revoke execute on function public.verify_audit_chain(uuid) from public;
grant  execute on function public.verify_audit_chain(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. domain_events — transactional outbox
-- ------------------------------------------------------------
create table if not exists public.domain_events (
  id             bigint generated always as identity primary key,
  occurred_at    timestamptz not null default now(),
  school_id      uuid,
  type           text not null,
  aggregate_type text,
  aggregate_id   uuid,
  payload        jsonb not null default '{}'::jsonb,
  request_id     uuid,
  published_at   timestamptz,
  attempts       int not null default 0,
  status         text not null default 'pending' check (status in ('pending','published','dead'))
);
create index if not exists domain_events_pending_idx on public.domain_events(id) where status='pending';
create index if not exists domain_events_school_idx  on public.domain_events(school_id, occurred_at);

alter table public.domain_events enable row level security;
create policy de_super on public.domain_events for select using (is_super_admin());
create policy de_admin on public.domain_events for select
  using (school_id = current_school_id() and my_role() in ('school_admin','branch_admin'));
revoke insert, update, delete, truncate on public.domain_events from authenticated, anon;

-- append-only except the dispatcher's whitelisted columns
create or replace function public.domain_events_guard() returns trigger
language plpgsql as $$
begin
  if TG_OP = 'DELETE' then
    raise exception 'domain_events للإضافة فقط' using errcode='2F004';
  end if;
  if (new.occurred_at, new.school_id, new.type, new.aggregate_type, new.aggregate_id, new.payload, new.request_id)
     is distinct from
     (old.occurred_at, old.school_id, old.type, old.aggregate_type, old.aggregate_id, old.payload, old.request_id) then
    raise exception 'domain_events: يُسمح فقط بتحديث حالة النشر' using errcode='2F004';
  end if;
  return new;
end $$;
drop trigger if exists domain_events_guard_trg on public.domain_events;
create trigger domain_events_guard_trg before update or delete on public.domain_events
  for each row execute function public.domain_events_guard();

create or replace function public.emit_event(
  p_type text, p_aggregate_type text, p_aggregate_id uuid, p_payload jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  insert into public.domain_events (school_id, type, aggregate_type, aggregate_id, payload, request_id)
  values (current_school_id(), p_type, p_aggregate_type, p_aggregate_id, coalesce(p_payload,'{}'::jsonb),
          nullif(current_setting('hamura.request_id', true), '')::uuid)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.emit_event(text,text,uuid,jsonb) from public;
grant  execute on function public.emit_event(text,text,uuid,jsonb) to authenticated, service_role;

-- minimal dispatcher: marks pending -> published (real consumers wired in
-- Phase 9 notifications). Run by pg_cron / an Edge cron.
create or replace function public.dispatch_domain_events(p_limit int default 200)
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not is_super_admin() and auth.uid() is not null then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  with picked as (
    select id from public.domain_events where status='pending' order by id limit p_limit for update skip locked
  )
  update public.domain_events d set status='published', published_at=now(), attempts=attempts+1
  from picked where d.id = picked.id;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.dispatch_domain_events(int) from public;
grant  execute on function public.dispatch_domain_events(int) to service_role;

-- ------------------------------------------------------------
-- 4. security_events
-- ------------------------------------------------------------
create table if not exists public.security_events (
  id          bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  user_id     uuid,
  school_id   uuid,
  type        text not null,      -- login.success|login.failed|mfa.*|session.revoked|permission.denied|impersonation.*
  outcome     text,
  ip          inet,
  user_agent  text,
  request_id  uuid,
  detail      jsonb not null default '{}'::jsonb
);
create index if not exists security_events_user_idx on public.security_events(user_id, occurred_at);
create index if not exists security_events_type_idx on public.security_events(type, occurred_at);

alter table public.security_events enable row level security;
create policy se_super on public.security_events for select using (is_super_admin());
create policy se_self  on public.security_events for select using (user_id = auth.uid());
create policy se_admin on public.security_events for select
  using (school_id = current_school_id() and my_role() in ('school_admin','branch_admin'));
revoke insert, update, delete, truncate on public.security_events from authenticated, anon;

drop trigger if exists security_events_immutable on public.security_events;
create trigger security_events_immutable before update or delete on public.security_events
  for each row execute function audit.deny_mutation();

create or replace function public.record_security_event(
  p_type text, p_outcome text default null, p_detail jsonb default '{}'::jsonb,
  p_user uuid default null, p_school uuid default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  insert into public.security_events (user_id, school_id, type, outcome, request_id, detail)
  values (coalesce(p_user, auth.uid()), coalesce(p_school, current_school_id()), p_type, p_outcome,
          nullif(current_setting('hamura.request_id', true), '')::uuid, coalesce(p_detail,'{}'::jsonb))
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.record_security_event(text,text,jsonb,uuid,uuid) from public;
grant  execute on function public.record_security_event(text,text,jsonb,uuid,uuid) to authenticated, service_role;

-- ------------------------------------------------------------
-- 5. audit_export_log — audits reads/exports of audit data
-- ------------------------------------------------------------
create table if not exists public.audit_export_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  by_user    uuid,
  school_id  uuid,
  target     text not null,     -- 'audit_events' | 'audit_log' | 'security_events' | 'report'
  filter     jsonb,
  row_count  int
);
alter table public.audit_export_log enable row level security;
create policy ael_super on public.audit_export_log for select using (is_super_admin());
create policy ael_admin on public.audit_export_log for select using (school_id = current_school_id() and my_role() in ('school_admin'));
revoke insert, update, delete, truncate on public.audit_export_log from authenticated, anon;

drop trigger if exists audit_export_log_immutable on public.audit_export_log;
create trigger audit_export_log_immutable before update or delete on public.audit_export_log
  for each row execute function audit.deny_mutation();

-- read audit_events through this so the read itself is recorded
create or replace function public.read_audit_events(
  p_action text default null, p_resource_type text default null,
  p_since timestamptz default now() - interval '30 days', p_limit int default 200)
returns setof public.audit_events
language plpgsql security definer set search_path = public as $$
begin
  if not (is_super_admin() or my_role() in ('school_admin')) then
    raise exception 'غير مصرح' using errcode='42501';
  end if;
  insert into public.audit_export_log (by_user, school_id, target, filter, row_count)
  values (auth.uid(), current_school_id(), 'audit_events',
          jsonb_build_object('action',p_action,'resource_type',p_resource_type,'since',p_since,'limit',p_limit), p_limit);

  return query
    select * from public.audit_events e
    where (is_super_admin() or e.school_id = current_school_id())
      and (p_action is null or e.action = p_action)
      and (p_resource_type is null or e.resource_type = p_resource_type)
      and e.occurred_at >= p_since
    order by e.id desc
    limit p_limit;
end $$;
revoke execute on function public.read_audit_events(text,text,timestamptz,int) from public;
grant  execute on function public.read_audit_events(text,text,timestamptz,int) to authenticated;

-- genesis event per existing school + platform, so the chain has a root
insert into public.audit_events (school_id, action, resource_type, row_hash)
select s.id, 'audit.chain_genesis', 'school', ''::bytea from public.schools s
union all select null, 'audit.chain_genesis', 'platform', ''::bytea;

commit;
