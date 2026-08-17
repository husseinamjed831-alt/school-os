-- ============================================================
-- School OS — 001: core multi-tenant schema
-- Depends on: nothing (first migration)
-- Run in the Supabase SQL Editor, in order, 001 through 007 —
-- see README.md "Supabase Setup" for the exact procedure.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- Tenancy ----------
create table schools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  logo_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table branches (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  name text not null,
  address text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, name)
);

create table academic_years (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  label text not null,               -- "2026-2027"
  starts_on date not null,
  ends_on date not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now(),
  unique (school_id, label)
);

-- ---------- Identity ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  school_id uuid references schools(id) on delete set null,
  branch_id uuid references branches(id) on delete set null,
  role text not null check (role in ('super_admin','school_admin','branch_admin','teacher','student','parent')),
  full_name text not null,
  phone text,
  telegram_chat_id bigint,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index profiles_school_idx on profiles(school_id);
create index profiles_role_idx on profiles(role);

-- ---------- Academic structure ----------
create table classes (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  academic_year_id uuid not null references academic_years(id) on delete cascade,
  grade_level int not null,
  name text not null,                -- "الأول متوسط"
  created_at timestamptz not null default now(),
  unique (branch_id, academic_year_id, grade_level, name)
);
create index classes_school_idx on classes(school_id);

create table sections (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  class_id uuid not null references classes(id) on delete cascade,
  name text not null,                -- "أ" "ب" "ج"
  capacity int,
  created_at timestamptz not null default now(),
  unique (class_id, name)
);
create index sections_school_idx on sections(school_id);

create table teachers (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  specialty text,
  created_at timestamptz not null default now(),
  unique (profile_id)
);
create index teachers_school_idx on teachers(school_id);

create table students (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  branch_id uuid references branches(id) on delete set null,  -- null until assigned a section
  profile_id uuid references profiles(id) on delete set null,  -- null until student gets a login
  parent_id uuid references profiles(id) on delete set null,
  section_id uuid references sections(id) on delete set null,
  full_name text not null,
  birth_date date,
  enrolled_at date not null default current_date,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index students_school_idx on students(school_id);
create index students_section_idx on students(section_id);
create index students_parent_idx on students(parent_id);

create table subjects (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  class_id uuid not null references classes(id) on delete cascade,
  teacher_id uuid references teachers(id) on delete set null,
  name text not null,
  created_at timestamptz not null default now()
);
create index subjects_school_idx on subjects(school_id);

create table schedule (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  section_id uuid not null references sections(id) on delete cascade,
  subject_id uuid not null references subjects(id) on delete cascade,
  day int not null check (day between 0 and 6),
  period int not null check (period between 1 and 8),
  created_at timestamptz not null default now(),
  unique (section_id, day, period)
);
create index schedule_school_idx on schedule(school_id);

create table attendance (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  date date not null default current_date,
  status text not null check (status in ('present','absent','late','excused')),
  recorded_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (student_id, date)
);
create index attendance_school_idx on attendance(school_id);

create table grades (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  subject_id uuid not null references subjects(id) on delete cascade,
  exam_type text not null check (exam_type in ('month1','month2','midterm','final')),
  score numeric(5,2) not null,
  max_score numeric(5,2) not null default 100,
  recorded_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (student_id, subject_id, exam_type)
);
create index grades_school_idx on grades(school_id);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  title text not null,
  body text,
  is_read boolean not null default false,
  sent_to_telegram boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_school_idx on notifications(school_id);
create index notifications_user_idx on notifications(user_id, is_read);
