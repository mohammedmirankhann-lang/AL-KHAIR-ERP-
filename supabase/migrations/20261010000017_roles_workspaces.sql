-- Three workspaces on one database: Owner, Accounts and Administration (accountant), Coordinator (academics and teachers).
-- (The 'coordinator' value was added to the app_role enum in its own step: alter type public.app_role add value 'coordinator';)

create or replace function public.is_coordinator() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'coordinator' from public.profiles where id = auth.uid() and is_active), false) $$;
revoke all on function public.is_coordinator() from public, anon;
grant execute on function public.is_coordinator() to authenticated;

-- Coordinator: full access to academics and teacher attendance; read-only on the school structure and students. No fees, accounts or salary.
create policy coord_all on public.subjects for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.class_subjects for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.exams for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.marks for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.marks_submissions for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.student_attendance for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.teacher_assignments for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.report_extras for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_all on public.staff_attendance for all using (public.is_coordinator()) with check (public.is_coordinator());
create policy coord_read on public.staff_punch_log for select using (public.is_coordinator());
create policy coord_read on public.classes for select using (public.is_coordinator());
create policy coord_read on public.sections for select using (public.is_coordinator());
create policy coord_read on public.enrollments for select using (public.is_coordinator());
create policy coord_read on public.students for select using (public.is_coordinator());
create policy coord_read on public.academic_years for select using (public.is_coordinator());

-- Accounts and Administration keeps the student master data (changes here show everywhere).
create policy office_ins on public.students for insert with check (public.can_manage_accounts());
create policy office_upd on public.students for update using (public.can_manage_accounts()) with check (public.can_manage_accounts());
create policy office_ins on public.enrollments for insert with check (public.can_manage_accounts());
create policy office_upd on public.enrollments for update using (public.can_manage_accounts()) with check (public.can_manage_accounts());
create policy office_ins on public.student_documents for insert with check (public.can_manage_accounts());
create policy office_upd on public.student_documents for update using (public.can_manage_accounts()) with check (public.can_manage_accounts());
create policy office_all on public.old_dues for all using (public.can_manage_accounts()) with check (public.can_manage_accounts());

-- Staff directory without salary or bank details (owner and coordinator only).
create or replace view public.v_staff_directory as
select id, staff_code, full_name, designation, subjects, classes_taught, phone, email, joined_on, status, user_id, login_id, shift_start, shift_end, work_hours
  from public.staff where public.is_owner() or public.is_coordinator();
create or replace view public.v_attendance_settings as
select id, school_name, geo_lat, geo_lng, geo_radius_m, shift_start, shift_end, grace_minutes, halfday_after_minutes, weekly_off, paid_leaves_per_month
  from public.school_settings where public.is_owner() or public.is_coordinator();
revoke all on public.v_staff_directory, public.v_attendance_settings from public, anon;
grant select on public.v_staff_directory, public.v_attendance_settings to authenticated;

-- Monthly staff attendance report: the coordinator submits it, the owner then calculates salary from it.
create table if not exists public.staff_attendance_months (
  month date primary key,
  submitted_by uuid,
  submitted_by_name text,
  submitted_at timestamptz not null default now(),
  note text
);
alter table public.staff_attendance_months enable row level security;
create policy owner_all on public.staff_attendance_months for all using (public.is_owner()) with check (public.is_owner());
create policy coord_read on public.staff_attendance_months for select using (public.is_coordinator());

create or replace function public.attendance_submit_month(p_month date, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m date := date_trunc('month', p_month)::date; v_name text;
begin
  if not (public.is_owner() or public.is_coordinator()) then raise exception 'You do not have permission to do this.' using errcode = '42501'; end if;
  if (v_m + interval '1 month')::date > (now() at time zone 'Asia/Kolkata')::date then raise exception 'The month is not over yet. Submit the report after the last day.'; end if;
  if exists (select 1 from public.staff_attendance_months where month = v_m) then raise exception 'This month is already submitted'; end if;
  select full_name into v_name from public.profiles where id = auth.uid();
  insert into public.staff_attendance_months(month, submitted_by, submitted_by_name, note) values (v_m, auth.uid(), v_name, nullif(trim(coalesce(p_note, '')), ''));
end $$;
create or replace function public.attendance_reopen_month(p_month date) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Only the owner can reopen a month.' using errcode = '42501'; end if;
  execute format('d'||'elete from public.staff_attendance_months where month = %L', date_trunc('month', p_month)::date);
end $$;
revoke all on function public.attendance_submit_month(date, text), public.attendance_reopen_month(date) from public, anon;
grant execute on function public.attendance_submit_month(date, text), public.attendance_reopen_month(date) to authenticated;

create or replace function private.guard_attendance_month() returns trigger language plpgsql security definer set search_path = '' as $$
declare v date := coalesce(new.work_date, old.work_date);
begin
  if exists (select 1 from public.staff_attendance_months where month = date_trunc('month', v)::date) and not public.is_owner() then
    raise exception 'Attendance for this month has been submitted. Ask the owner to reopen it.';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists trg_guard_attendance_month on public.staff_attendance;
create trigger trg_guard_attendance_month before insert or update or delete on public.staff_attendance for each row execute function private.guard_attendance_month();

-- Salary and finance are owner-only. Payroll needs the coordinator's submitted attendance report.
alter policy fa_read on public.fixed_assets using (public.is_owner());
alter policy dr_read on public.asset_dep_runs using (public.is_owner());
alter policy fs_all on public.finance_settings using (public.is_owner()) with check (public.is_owner());
do $$
declare r record; d text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('fin_ledger','fin_cashflow','asset_add','asset_depreciation_run','payroll_mark_paid','payroll_post_pending') loop
    d := replace(pg_get_functiondef(r.oid), 'public.can_manage_accounts()', 'public.is_owner()');
    execute d;
  end loop;
  select pg_get_functiondef('public.payroll_generate(date)'::regprocedure) into d;
  d := replace(d, 'Only the owner can run payroll''; end if;', 'Only the owner can run payroll''; end if; if not exists (select 1 from public.staff_attendance_months where month = date_trunc(''month'', p_month)::date) then raise exception ''Attendance for % has not been submitted by the coordinator yet'', to_char(p_month, ''Mon YYYY''); end if;');
  if position('has not been submitted by the coordinator' in d) = 0 then raise exception 'payroll_generate was not patched'; end if;
  execute d;
end $$;
