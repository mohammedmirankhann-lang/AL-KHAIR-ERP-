-- Academics: subjects, class subjects, exams (PT1, Term 1, PT2, Term 2), marks. Owner-only for now.
create table if not exists subjects (id uuid primary key default gen_random_uuid(), name text not null unique, sort_order int not null default 0);
create table if not exists class_subjects (class_id uuid not null references classes(id) on delete cascade, subject_id uuid not null references subjects(id) on delete cascade, primary key (class_id, subject_id));
create table if not exists exams (id uuid primary key default gen_random_uuid(), academic_year_id uuid not null references academic_years(id), name text not null, short_name text not null, sort_order int not null default 0, default_max numeric(6,2) not null default 100, unique (academic_year_id, name));
create table if not exists marks (id uuid primary key default gen_random_uuid(), exam_id uuid not null references exams(id) on delete cascade, enrollment_id uuid not null references enrollments(id) on delete cascade, subject_id uuid not null references subjects(id), marks numeric(6,2), max_marks numeric(6,2) not null, absent boolean not null default false, entered_by uuid, updated_at timestamptz not null default now(), unique (exam_id, enrollment_id, subject_id), check (marks is null or (marks >= 0 and marks <= max_marks)));
alter table subjects enable row level security; alter table class_subjects enable row level security; alter table exams enable row level security; alter table marks enable row level security;
create policy owner_all on subjects for all using (is_owner()) with check (is_owner());
create policy owner_all on class_subjects for all using (is_owner()) with check (is_owner());
create policy owner_all on exams for all using (is_owner()) with check (is_owner());
create policy owner_all on marks for all using (is_owner()) with check (is_owner());
-- seed (editable in Academics > Setup): starter subjects, 4 exams per session with max 100
