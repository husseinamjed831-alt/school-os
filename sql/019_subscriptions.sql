-- ============================================================
-- School OS — 019: subscriptions & entitlements (V1 Phase 7, migration M7)
-- Depends on: 001 (schools), 011 (schools.subscription_status), 013
--   (current_school_id, school_is_operational), 016 (emit_event,
--   record_audit_event).
--
-- Replaces the informational schools.subscription_status with real
-- entitlement enforcement. Existing tenants -> 'legacy_unlimited' (no
-- limits, zero behaviour change). Billing-provider integration is a thin
-- separate surface (subscription_gateway_event()) so it can be wired later
-- without touching authorization.
--
-- Rollback: sql/019_subscriptions_rollback.sql   Tests: sql/tests/019_subscriptions.sql
-- ============================================================

begin;

-- ---------- plans ----------
create table if not exists public.plans (
  code           text primary key,
  name           text not null,
  price          numeric(10,2) not null default 0,
  billing_period text not null default 'month' check (billing_period in ('month','year','none')),
  limits         jsonb not null default '{}'::jsonb,     -- {students, staff, branches, storage_mb, ai_credits}
  features       jsonb not null default '{}'::jsonb,     -- {report_engine, comms, api, vision_ai}
  is_active      boolean not null default true,
  sort           int not null default 0
);
alter table public.plans enable row level security;
create policy plans_read  on public.plans for select using (auth.uid() is not null);
create policy plans_admin on public.plans for all using (is_super_admin()) with check (is_super_admin());

insert into public.plans (code, name, price, billing_period, limits, features, sort) values
 ('legacy_unlimited','مخصّص', 0, 'none',
    '{"students":null,"staff":null,"branches":null,"storage_mb":null,"ai_credits":null}'::jsonb,
    '{"report_engine":true,"comms":true,"api":true,"vision_ai":false}'::jsonb, 0),
 ('starter','المبتدئة', 0, 'month',
    '{"students":150,"staff":20,"branches":1,"storage_mb":1024,"ai_credits":0}'::jsonb,
    '{"report_engine":true,"comms":true,"api":false,"vision_ai":false}'::jsonb, 1),
 ('professional','الاحترافية', 49, 'month',
    '{"students":1000,"staff":120,"branches":3,"storage_mb":10240,"ai_credits":500}'::jsonb,
    '{"report_engine":true,"comms":true,"api":true,"vision_ai":false}'::jsonb, 2),
 ('enterprise','المؤسسية', 199, 'month',
    '{"students":null,"staff":null,"branches":null,"storage_mb":102400,"ai_credits":5000}'::jsonb,
    '{"report_engine":true,"comms":true,"api":true,"vision_ai":true}'::jsonb, 3)
on conflict (code) do nothing;

-- ---------- subscriptions ----------
create table if not exists public.subscriptions (
  school_id          uuid primary key references public.schools(id) on delete cascade,
  plan_code          text not null references public.plans(code),
  status             text not null default 'trialing'
                       check (status in ('trialing','active','past_due','grace','suspended','canceled')),
  trial_ends_at      timestamptz,
  current_period_end timestamptz,
  grace_until        timestamptz,
  canceled_at        timestamptz,
  seats              int,
  updated_at         timestamptz not null default now()
);
alter table public.subscriptions enable row level security;
create policy sub_super on public.subscriptions for all using (is_super_admin()) with check (is_super_admin());
create policy sub_read  on public.subscriptions for select
  using (school_id = current_school_id());
create policy sub_owner_update on public.subscriptions for update
  using (school_id = current_school_id() and my_role() in ('school_admin')  -- school_owner mirrors to school_admin
         and has_perm('subscription.update','SCHOOL'))
  with check (school_id = current_school_id());
create trigger audit_subscriptions after insert or update or delete on public.subscriptions
  for each row execute function audit.log_change();

create table if not exists public.subscription_events (
  id          bigint generated always as identity primary key,
  school_id   uuid not null references public.schools(id) on delete cascade,
  from_status text,
  to_status   text,
  reason      text,
  actor       uuid,
  effective_at timestamptz not null default now(),
  meta        jsonb not null default '{}'::jsonb
);
alter table public.subscription_events enable row level security;
create policy se_super on public.subscription_events for select using (is_super_admin());
create policy se_read  on public.subscription_events for select using (school_id = current_school_id());
revoke insert, update, delete, truncate on public.subscription_events from authenticated, anon;

-- ---------- usage counters ----------
create table if not exists public.usage_counters (
  school_id  uuid not null references public.schools(id) on delete cascade,
  metric     text not null,
  value      bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (school_id, metric)
);
alter table public.usage_counters enable row level security;
create policy uc_super on public.usage_counters for all using (is_super_admin()) with check (is_super_admin());
create policy uc_read  on public.usage_counters for select using (school_id = current_school_id());
revoke insert, update, delete, truncate on public.usage_counters from authenticated, anon;

create table if not exists public.school_feature_overrides (
  school_id  uuid not null references public.schools(id) on delete cascade,
  key        text not null,
  value      jsonb not null,
  granted_by uuid references public.profiles(id) on delete set null,
  expires_at timestamptz,
  primary key (school_id, key)
);
alter table public.school_feature_overrides enable row level security;
create policy sfo_super on public.school_feature_overrides for all using (is_super_admin()) with check (is_super_admin());
create policy sfo_read  on public.school_feature_overrides for select using (school_id = current_school_id());

-- ---------- entitlement helpers ----------
create or replace function public.plan_limit(p_school uuid, p_metric text)
returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (o.value #>> '{}')::bigint from public.school_feature_overrides o
      where o.school_id = p_school and o.key = 'limit.'||p_metric
        and (o.expires_at is null or o.expires_at > now())),
    (select nullif(p.limits ->> p_metric, 'null')::bigint
       from public.subscriptions s join public.plans p on p.code = s.plan_code
      where s.school_id = p_school)
  )
$$;
revoke execute on function public.plan_limit(uuid,text) from public;
grant  execute on function public.plan_limit(uuid,text) to authenticated, service_role;

create or replace function public.has_feature(p_school uuid, p_key text)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (o.value)::boolean from public.school_feature_overrides o
      where o.school_id = p_school and o.key = 'feature.'||p_key
        and (o.expires_at is null or o.expires_at > now())),
    (select coalesce((p.features ->> p_key)::boolean, false)
       from public.subscriptions s join public.plans p on p.code = s.plan_code
      where s.school_id = p_school),
    false)
$$;
revoke execute on function public.has_feature(uuid,text) from public;
grant  execute on function public.has_feature(uuid,text) to authenticated, service_role;

-- assert_quota: raise on hard breach; return 'ok' | 'soft_over' | 'hard_over'
create or replace function public.assert_quota(p_school uuid, p_metric text, p_delta int default 1)
returns text
language plpgsql security definer set search_path = public as $$
declare v_limit bigint; v_used bigint; v_after bigint;
begin
  v_limit := public.plan_limit(p_school, p_metric);
  if v_limit is null then return 'ok'; end if;             -- unlimited (legacy/enterprise)
  select value into v_used from public.usage_counters where school_id = p_school and metric = p_metric;
  v_after := coalesce(v_used, 0) + p_delta;
  if v_after > v_limit then
    perform public.emit_event('QuotaHardBreached','subscription', null,
      jsonb_build_object('school_id',p_school,'metric',p_metric,'limit',v_limit,'attempted',v_after));
    raise exception 'تم بلوغ الحد الأقصى للخطة (% : % / %)', p_metric, v_after, v_limit using errcode='P0001';
  elsif v_after > (v_limit * 0.9)::bigint then
    perform public.emit_event('QuotaSoftBreached','subscription', null,
      jsonb_build_object('school_id',p_school,'metric',p_metric,'limit',v_limit,'used',v_after));
    return 'soft_over';
  end if;
  return 'ok';
end $$;
revoke execute on function public.assert_quota(uuid,text,int) from public;
grant  execute on function public.assert_quota(uuid,text,int) to authenticated, service_role;

-- ---------- extend school_is_operational to honour subscription status ----------
create or replace function public.school_is_operational(p_school uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.is_active from public.schools s where s.id = p_school), false)
     and coalesce(
       (select sub.status not in ('suspended','canceled')
          from public.subscriptions sub where sub.school_id = p_school),
       true)   -- no subscription row yet -> treat as operational
$$;

-- ---------- usage recount + increment triggers ----------
create or replace function public.recount_usage(p_school uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.usage_counters (school_id, metric, value, updated_at) values
    (p_school,'students', (select count(*) from public.students where school_id=p_school and is_active), now()),
    (p_school,'staff',    (select count(*) from public.teachers where school_id=p_school), now()),
    (p_school,'branches', (select count(*) from public.branches where school_id=p_school and is_active), now())
  on conflict (school_id, metric) do update set value = excluded.value, updated_at = now();
end $$;
revoke execute on function public.recount_usage(uuid) from public;
grant  execute on function public.recount_usage(uuid) to service_role;

create or replace function public.trg_usage_delta() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_metric text := TG_ARGV[0]; v_school uuid; v_d int;
begin
  if TG_OP = 'INSERT' then v_school := new.school_id; v_d := 1;
  elsif TG_OP = 'DELETE' then v_school := old.school_id; v_d := -1;
  else return null; end if;
  insert into public.usage_counters (school_id, metric, value) values (v_school, v_metric, greatest(v_d,0))
  on conflict (school_id, metric) do update set value = greatest(public.usage_counters.value + v_d, 0), updated_at = now();
  return null;
end $$;
create trigger usage_students after insert or delete on public.students
  for each row execute function public.trg_usage_delta('students');
create trigger usage_staff after insert or delete on public.teachers
  for each row execute function public.trg_usage_delta('staff');
create trigger usage_branches after insert or delete on public.branches
  for each row execute function public.trg_usage_delta('branches');

-- ---------- change_subscription + mirror ----------
create or replace function public.change_subscription(p_plan text, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_school uuid := current_school_id(); v_old text;
begin
  if not (is_super_admin() or has_perm('subscription.update','SCHOOL')) then
    raise exception 'غير مصرح — تغيير الاشتراك يتطلب صلاحية المالك' using errcode='42501';
  end if;
  if not exists (select 1 from public.plans where code = p_plan and is_active) then
    raise exception 'خطة غير معروفة' using errcode='22023';
  end if;
  select status into v_old from public.subscriptions where school_id = v_school;
  update public.subscriptions set plan_code = p_plan, status = 'active', updated_at = now()
   where school_id = v_school;
  insert into public.subscription_events (school_id, from_status, to_status, reason, actor, meta)
  values (v_school, v_old, 'active', coalesce(p_reason,'plan change'), auth.uid(), jsonb_build_object('plan', p_plan));
  update public.schools set subscription_status =
    case p_plan when 'legacy_unlimited' then 'active' else 'active' end where id = v_school;
  perform public.record_audit_event('subscription.changed','subscription', null,
    jsonb_build_object('from',v_old), jsonb_build_object('plan',p_plan,'status','active'));
  perform public.emit_event('SubscriptionChanged','subscription', v_school, jsonb_build_object('plan',p_plan));
end $$;
revoke execute on function public.change_subscription(text,text) from public;
grant  execute on function public.change_subscription(text,text) to authenticated;

-- thin billing-gateway seam (no provider wired yet)
create or replace function public.subscription_gateway_event(p_school uuid, p_to_status text, p_meta jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  if not is_super_admin() then raise exception 'غير مصرح' using errcode='42501'; end if;  -- service_role bypasses
  select status into v_old from public.subscriptions where school_id = p_school;
  update public.subscriptions set status = p_to_status, updated_at = now(),
         grace_until = case when p_to_status='grace' then now() + interval '7 days' else grace_until end,
         canceled_at = case when p_to_status='canceled' then now() else canceled_at end
   where school_id = p_school;
  insert into public.subscription_events (school_id, from_status, to_status, reason, meta)
  values (p_school, v_old, p_to_status, 'gateway', p_meta);
  update public.schools set subscription_status =
    case when p_to_status in ('suspended','canceled') then 'suspended'
         when p_to_status = 'trialing' then 'trial' else 'active' end
   where id = p_school;
  perform public.emit_event('SubscriptionChanged','subscription', p_school, jsonb_build_object('status',p_to_status));
end $$;
revoke execute on function public.subscription_gateway_event(uuid,text,jsonb) from public, authenticated;
grant  execute on function public.subscription_gateway_event(uuid,text,jsonb) to service_role;

-- ---------- backfill ----------
insert into public.subscriptions (school_id, plan_code, status, trial_ends_at, current_period_end)
select s.id,
       case when s.subscription_status = 'trial' then 'starter' else 'legacy_unlimited' end,
       case when s.subscription_status = 'trial' then 'trialing'
            when s.subscription_status = 'suspended' then 'suspended' else 'active' end,
       case when s.subscription_status = 'trial' then s.created_at + interval '30 days' end,
       now() + interval '100 years'
from public.schools s
where not exists (select 1 from public.subscriptions x where x.school_id = s.id);

-- seed usage counters from current state
do $$ declare r record; begin
  for r in select id from public.schools loop perform public.recount_usage(r.id); end loop;
end $$;

-- hard-quota guard on the most abuse-prone create paths (defence in depth
-- over the RPC-level assert_quota). Only bites for limited plans.
create or replace function public.trg_students_quota_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or is_super_admin() then return new; end if;
  perform public.assert_quota(coalesce(public.current_school_id(), new.school_id), 'students', 1);
  if not public.school_is_operational(coalesce(public.current_school_id(), new.school_id)) then
    raise exception 'المدرسة موقوفة — لا يمكن إضافة طلاب' using errcode='42501';
  end if;
  return new;
end $$;
create trigger students_quota_guard before insert on public.students
  for each row execute function public.trg_students_quota_guard();

commit;
