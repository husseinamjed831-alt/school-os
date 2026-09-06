begin;
drop trigger if exists students_quota_guard on public.students;
drop function if exists public.trg_students_quota_guard();
drop trigger if exists usage_students on public.students;
drop trigger if exists usage_staff on public.teachers;
drop trigger if exists usage_branches on public.branches;
drop function if exists public.trg_usage_delta();
drop function if exists public.subscription_gateway_event(uuid,text,jsonb);
drop function if exists public.change_subscription(text,text);
drop function if exists public.recount_usage(uuid);
drop function if exists public.assert_quota(uuid,text,int);
drop function if exists public.has_feature(uuid,text);
drop function if exists public.plan_limit(uuid,text);

-- restore 013's school_is_operational (subscription-agnostic)
create or replace function public.school_is_operational(p_school uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select s.is_active and s.subscription_status is distinct from 'suspended'
    from public.schools s where s.id = p_school), false)
$$;

drop table if exists public.school_feature_overrides;
drop table if exists public.usage_counters;
drop table if exists public.subscription_events;
drop table if exists public.subscriptions;
drop table if exists public.plans;
commit;
