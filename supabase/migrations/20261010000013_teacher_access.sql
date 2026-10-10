-- Teacher access: assignments, student attendance, scoped marks entry.
-- Teachers never read tables directly; they use the functions below, which check the teacher's own assignments.

create table if not exists teacher_assignments (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id) on delete cascade,
  class_id uuid not null references classes(id) on delete cascade,
  subject_id uuid references subjects(id) on delete cascade,
  is_class_teacher boolean not null default false,
  created_at timestamptz not null default now(),
  check (is_class_teacher or subject_id is not null),
  unique nulls not distinct (staff_id, class_id, subject_id, is_class_teacher)
);
create table if not exists student_attendance (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id) on delete cascade,
  att_date date not null,
  status text not null check (status in ('present','absent','late','leave')),
  marked_by uuid,
  updated_at timestamptz not null default now(),
  unique (enrollment_id, att_date)
);
create index if not exists student_attendance_date_idx on student_attendance (att_date);
create table if not exists marks_submissions (
  exam_id uuid not null references exams(id) on delete cascade,
  class_id uuid not null references classes(id) on delete cascade,
  subject_id uuid not null references subjects(id) on delete cascade,
  submitted_by uuid,
  submitted_at timestamptz not null default now(),
  primary key (exam_id, class_id, subject_id)
);
alter table teacher_assignments enable row level security;
alter table student_attendance enable row level security;
alter table marks_submissions enable row level security;
create policy owner_all on teacher_assignments for all using (is_owner()) with check (is_owner());
create policy owner_all on student_attendance for all using (is_owner()) with check (is_owner());
create policy owner_all on marks_submissions for all using (is_owner()) with check (is_owner());

create or replace function private.me_staff() returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.staff where user_id = auth.uid() and status = 'active' limit 1 $$;
create or replace function private.require_class(p_class uuid, p_subject uuid, p_class_teacher boolean) returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.teacher_assignments a where a.staff_id = private.me_staff() and a.class_id = p_class
      and ((p_class_teacher and a.is_class_teacher) or (not p_class_teacher and p_subject is not null and a.subject_id = p_subject))) then
    raise exception 'You are not assigned to this class' using errcode = '42501';
  end if;
end $$;
create or replace function private.today_ist() returns date language sql stable set search_path = '' as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace function public.teacher_my_assignments()
returns table(class_id uuid, class_name text, subject_id uuid, subject_name text, is_class_teacher boolean)
language sql stable security definer set search_path = '' as $$
  select a.class_id, c.name, a.subject_id, s.name, a.is_class_teacher
  from public.teacher_assignments a join public.classes c on c.id = a.class_id left join public.subjects s on s.id = a.subject_id
  where a.staff_id = private.me_staff() order by c.sort_order, s.sort_order $$;

create or replace function public.teacher_exams() returns table(id uuid, name text, short_name text, default_max numeric)
language sql stable security definer set search_path = '' as $$
  select e.id, e.name, e.short_name, e.default_max from public.exams e join public.academic_years y on y.id = e.academic_year_id
  where y.is_current and private.me_staff() is not null order by e.sort_order $$;

create or replace function public.teacher_roster(p_class uuid)
returns table(enrollment_id uuid, roll_no int, admission_no text, full_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.teacher_assignments a where a.staff_id = private.me_staff() and a.class_id = p_class) then
    raise exception 'You are not assigned to this class' using errcode = '42501';
  end if;
  return query select e.id, e.roll_no, s.admission_no, s.full_name
    from public.enrollments e join public.students s on s.id = e.student_id join public.academic_years y on y.id = e.academic_year_id
    where y.is_current and e.class_id = p_class and e.status = 'enrolled' order by e.roll_no nulls last, s.full_name;
end $$;

create or replace function public.teacher_get_marks(p_exam uuid, p_class uuid, p_subject uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_class(p_class, p_subject, false);
  select jsonb_build_object(
    'submitted', exists (select 1 from public.marks_submissions where exam_id = p_exam and class_id = p_class and subject_id = p_subject),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('enrollment_id', m.enrollment_id, 'marks', m.marks, 'max_marks', m.max_marks, 'absent', m.absent))
       from public.marks m join public.enrollments e on e.id = m.enrollment_id where m.exam_id = p_exam and m.subject_id = p_subject and e.class_id = p_class), '[]'::jsonb)) into v;
  return v;
end $$;

create or replace function public.teacher_save_marks(p_exam uuid, p_class uuid, p_subject uuid, p_max numeric, p_rows jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare r jsonb; n int := 0; v_marks numeric; v_abs boolean;
begin
  perform private.require_class(p_class, p_subject, false);
  if exists (select 1 from public.marks_submissions where exam_id = p_exam and class_id = p_class and subject_id = p_subject) then
    raise exception 'These marks are already submitted. Ask the principal to unlock them.';
  end if;
  if p_max is null or p_max <= 0 then raise exception 'Maximum marks must be more than zero'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if not exists (select 1 from public.enrollments e where e.id = (r ->> 'enrollment_id')::uuid and e.class_id = p_class) then
      raise exception 'A student in the list is not in this class';
    end if;
    v_abs := coalesce((r ->> 'absent')::boolean, false);
    v_marks := case when v_abs or coalesce(r ->> 'marks', '') = '' then null else (r ->> 'marks')::numeric end;
    if v_marks is null and not v_abs then continue; end if;
    if v_marks is not null and (v_marks < 0 or v_marks > p_max) then raise exception 'Marks must be between 0 and %', p_max; end if;
    insert into public.marks(exam_id, enrollment_id, subject_id, marks, max_marks, absent, entered_by, updated_at)
    values (p_exam, (r ->> 'enrollment_id')::uuid, p_subject, v_marks, p_max, v_abs, auth.uid(), now())
    on conflict (exam_id, enrollment_id, subject_id) do update set marks = excluded.marks, max_marks = excluded.max_marks, absent = excluded.absent, entered_by = excluded.entered_by, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.teacher_submit_marks(p_exam uuid, p_class uuid, p_subject uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_class(p_class, p_subject, false);
  insert into public.marks_submissions(exam_id, class_id, subject_id, submitted_by) values (p_exam, p_class, p_subject, auth.uid()) on conflict do nothing;
end $$;

create or replace function public.teacher_get_attendance(p_class uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_class(p_class, null, true);
  return coalesce((select jsonb_agg(jsonb_build_object('enrollment_id', a.enrollment_id, 'status', a.status))
    from public.student_attendance a join public.enrollments e on e.id = a.enrollment_id where e.class_id = p_class and a.att_date = p_date), '[]'::jsonb);
end $$;

create or replace function public.teacher_save_attendance(p_class uuid, p_date date, p_rows jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare r jsonb; n int := 0;
begin
  perform private.require_class(p_class, null, true);
  if p_date > private.today_ist() then raise exception 'You cannot mark attendance for a future date'; end if;
  if p_date < private.today_ist() - 7 then raise exception 'Attendance older than 7 days can only be changed by the principal'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if not exists (select 1 from public.enrollments e where e.id = (r ->> 'enrollment_id')::uuid and e.class_id = p_class) then
      raise exception 'A student in the list is not in this class';
    end if;
    insert into public.student_attendance(enrollment_id, att_date, status, marked_by, updated_at)
    values ((r ->> 'enrollment_id')::uuid, p_date, r ->> 'status', auth.uid(), now())
    on conflict (enrollment_id, att_date) do update set status = excluded.status, marked_by = excluded.marked_by, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.teacher_my_assignments(), public.teacher_exams(), public.teacher_roster(uuid), public.teacher_get_marks(uuid,uuid,uuid),
  public.teacher_save_marks(uuid,uuid,uuid,numeric,jsonb), public.teacher_submit_marks(uuid,uuid,uuid), public.teacher_get_attendance(uuid,date), public.teacher_save_attendance(uuid,date,jsonb) from public, anon;
grant execute on function public.teacher_my_assignments(), public.teacher_exams(), public.teacher_roster(uuid), public.teacher_get_marks(uuid,uuid,uuid),
  public.teacher_save_marks(uuid,uuid,uuid,numeric,jsonb), public.teacher_submit_marks(uuid,uuid,uuid), public.teacher_get_attendance(uuid,date), public.teacher_save_attendance(uuid,date,jsonb) to authenticated;
revoke all on function private.me_staff(), private.require_class(uuid,uuid,boolean), private.today_ist() from public, anon, authenticated;
