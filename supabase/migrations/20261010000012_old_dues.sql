-- Previous-session fee dues for students who are not in this session: kept separate, never added to this session's fees.
-- If the student is linked to a current student, a note shows on that student's profile.
create table if not exists old_dues (
  id uuid primary key default gen_random_uuid(),
  year_label text not null,
  source_history_id uuid references fee_year_history(id),
  old_admission_no text,
  student_name text not null,
  class_name text,
  amount numeric(10,2) not null check (amount > 0),
  student_id uuid references students(id),
  status text not null default 'open' check (status in ('open','linked','cleared','written_off')),
  note text,
  created_at timestamptz not null default now(),
  unique (source_history_id)
);
alter table old_dues enable row level security;
create policy owner_all on old_dues for all using (is_owner()) with check (is_owner());
insert into old_dues(year_label, source_history_id, old_admission_no, student_name, class_name, amount)
select year_label, id, admission_no, student_name, class_name, due from fee_year_history where due > 0 and student_id is null
on conflict (source_history_id) do nothing;
