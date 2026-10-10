-- Teacher assignments belong to a session; staff codes (AKA1...) are unique per person.
create or replace function private.current_year() returns uuid language sql stable set search_path = '' as $$ select id from public.academic_years where is_current limit 1 $$;
grant execute on function private.current_year() to authenticated;
alter table teacher_assignments add column if not exists academic_year_id uuid references academic_years(id);
update teacher_assignments set academic_year_id = private.current_year() where academic_year_id is null and id is not null;
alter table teacher_assignments alter column academic_year_id set not null;
alter table teacher_assignments alter column academic_year_id set default private.current_year();
alter table teacher_assignments drop constraint if exists teacher_assignments_staff_id_class_id_subject_id_is_class_teacher_key;
alter table teacher_assignments add constraint teacher_assignments_unique_per_year unique nulls not distinct (academic_year_id, staff_id, class_id, subject_id, is_class_teacher);
create unique index if not exists staff_code_unique on staff (upper(staff_code)) where staff_code is not null;
-- require_class, teacher_my_assignments and teacher_roster were redefined to filter on the current session (see database).
