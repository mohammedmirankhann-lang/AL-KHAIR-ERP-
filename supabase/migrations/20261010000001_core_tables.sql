-- Al-Khair Academy ERP, release 1: core tables
-- Students, documents, fees, double-entry accounts, payments, audit.
-- Written for Supabase (Postgres 15+). Money tables are written only through the
-- functions in migration 0002; direct writes are blocked in migration 0004.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Nothing is granted to the anonymous role by default.
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema public revoke execute on functions from public;

-- ---------------------------------------------------------------- people / roles
create type public.app_role as enum ('owner', 'accountant', 'teacher');

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null,
  role        public.app_role not null default 'teacher',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.school_settings (
  id                  boolean primary key default true check (id),
  school_name         text not null default 'Al-Khair Academy',
  books_locked_until  date,
  updated_at          timestamptz not null default now()
);

-- ---------------------------------------------------------------- academic structure
create table public.academic_years (
  id          uuid primary key default gen_random_uuid(),
  label       text not null unique,                       -- e.g. 2026-27
  starts_on   date not null,
  ends_on     date not null check (ends_on > starts_on),
  is_current  boolean not null default false
);
create unique index uq_one_current_year on public.academic_years (is_current) where is_current;

create table public.classes (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  sort_order  integer not null unique
);

create table public.sections (
  id        uuid primary key default gen_random_uuid(),
  class_id  uuid not null references public.classes (id) on delete cascade,
  name      text not null,
  unique (class_id, name)
);

-- ---------------------------------------------------------------- students
create table public.students (
  id               uuid primary key default gen_random_uuid(),
  admission_no     text not null unique,
  full_name        text not null,
  dob              date,
  gender           text check (gender in ('male', 'female', 'other')),
  father_name      text,
  mother_name      text,
  guardian_mobile  text,
  alt_mobile       text,
  address          text,
  pen              text,
  samagra_id       text,
  apaar_id         text,
  aadhaar_last4    text check (aadhaar_last4 ~ '^[0-9]{4}$'),
  family_id        text,
  admission_date   date,
  status           text not null default 'active'
                   check (status in ('active', 'left', 'passed_out', 'tc_issued')),
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index idx_students_name on public.students (lower(full_name));
create index idx_students_family on public.students (family_id);

create table public.enrollments (
  id                uuid primary key default gen_random_uuid(),
  student_id        uuid not null references public.students (id) on delete restrict,
  academic_year_id  uuid not null references public.academic_years (id),
  class_id          uuid not null references public.classes (id),
  section_id        uuid references public.sections (id),
  roll_no           integer,
  status            text not null default 'enrolled'
                    check (status in ('enrolled', 'promoted', 'left', 'repeated')),
  created_at        timestamptz not null default now(),
  unique (student_id, academic_year_id)
);
create index idx_enrollments_year_class on public.enrollments (academic_year_id, class_id);

-- ---------------------------------------------------------------- documents
create table public.document_types (
  id                     uuid primary key default gen_random_uuid(),
  code                   text not null unique,
  name                   text not null,
  required_from_order    integer not null default 0,  -- required for classes with sort_order >= this
  is_active              boolean not null default true
);

create table public.student_documents (
  id                uuid primary key default gen_random_uuid(),
  student_id        uuid not null references public.students (id) on delete cascade,
  document_type_id  uuid not null references public.document_types (id),
  status            text not null default 'received' check (status in ('received', 'not_applicable')),
  received_on       date,
  storage_path      text,
  notes             text,
  created_at        timestamptz not null default now(),
  unique (student_id, document_type_id)
);

-- ---------------------------------------------------------------- chart of accounts
create table public.accounts (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  type        text not null check (type in ('asset', 'liability', 'equity', 'income', 'expense')),
  is_system   boolean not null default false,
  is_active   boolean not null default true
);

-- ---------------------------------------------------------------- fees
create table public.fee_heads (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique,
  name                text not null,
  income_account_id   uuid not null references public.accounts (id),
  is_active           boolean not null default true
);

create table public.fee_structure (
  id                uuid primary key default gen_random_uuid(),
  academic_year_id  uuid not null references public.academic_years (id),
  class_id          uuid not null references public.classes (id),
  fee_head_id       uuid not null references public.fee_heads (id),
  amount            numeric(12,2) not null check (amount >= 0),
  unique (academic_year_id, class_id, fee_head_id)
);

-- Per-student fee lines (copied from the class structure, editable per student).
create table public.fee_assessments (
  id             uuid primary key default gen_random_uuid(),
  enrollment_id  uuid not null references public.enrollments (id) on delete cascade,
  fee_head_id    uuid not null references public.fee_heads (id),
  amount         numeric(12,2) not null check (amount >= 0),
  unique (enrollment_id, fee_head_id)
);

create table public.fee_discounts (
  id               uuid primary key default gen_random_uuid(),
  enrollment_id    uuid not null references public.enrollments (id) on delete cascade,
  fee_head_id      uuid references public.fee_heads (id),   -- null = applies to the total fee
  amount           numeric(12,2) not null check (amount > 0),
  reason           text not null,
  approved_by      text,
  status           text not null default 'active' check (status in ('active', 'reversed')),
  created_by       uuid references public.profiles (id),
  created_at       timestamptz not null default now(),
  reversed_at      timestamptz,
  reversed_reason  text
);

-- Previous-year dues (positive) or advance (negative) carried into an enrollment.
create table public.fee_opening_balances (
  enrollment_id  uuid primary key references public.enrollments (id) on delete cascade,
  amount         numeric(12,2) not null,
  note           text
);

-- What has already been posted to the books for each enrollment, by kind.
create table public.fee_posting_ledger (
  id             uuid primary key default gen_random_uuid(),
  enrollment_id  uuid not null references public.enrollments (id) on delete cascade,
  kind           text not null check (kind in ('assessment', 'concession', 'opening')),
  fee_head_id    uuid references public.fee_heads (id),
  amount_posted  numeric(12,2) not null default 0
);
create unique index uq_fee_posting_ledger on public.fee_posting_ledger
  (enrollment_id, kind, (coalesce(fee_head_id, '00000000-0000-0000-0000-000000000000'::uuid)));

-- Imported month totals from earlier years, used for trends and forecasts.
create table public.fee_collection_history (
  id                uuid primary key default gen_random_uuid(),
  month             date not null check (month = date_trunc('month', month)::date),
  academic_year_id  uuid references public.academic_years (id),
  class_id          uuid references public.classes (id),
  amount            numeric(14,2) not null,
  source            text not null default 'import'
);
create index idx_fee_history_month on public.fee_collection_history (month);

-- ---------------------------------------------------------------- books
create table public.journal_entries (
  id                 uuid primary key default gen_random_uuid(),
  entry_date         date not null,
  memo               text not null,
  source_type        text not null,
  source_id          uuid,
  reverses_entry_id  uuid unique references public.journal_entries (id),
  is_opening         boolean not null default false,
  created_by         uuid,
  created_at         timestamptz not null default now()
);
create index idx_journal_entries_date on public.journal_entries (entry_date);

create table public.journal_lines (
  id          uuid primary key default gen_random_uuid(),
  entry_id    uuid not null references public.journal_entries (id),
  account_id  uuid not null references public.accounts (id),
  debit       numeric(14,2) not null default 0 check (debit >= 0),
  credit      numeric(14,2) not null default 0 check (credit >= 0),
  narration   text,
  check ((debit = 0) <> (credit = 0))
);
create index idx_journal_lines_entry on public.journal_lines (entry_id);
create index idx_journal_lines_account on public.journal_lines (account_id);

create table public.receipt_counters (
  academic_year_id  uuid primary key references public.academic_years (id),
  last_no           integer not null default 0
);

create table public.payments (
  id                uuid primary key default gen_random_uuid(),
  enrollment_id     uuid not null references public.enrollments (id),
  amount            numeric(12,2) not null check (amount > 0),
  mode              text not null check (mode in ('cash', 'upi', 'bank_transfer', 'cheque', 'card', 'other')),
  reference         text,
  paid_on           date not null default current_date,
  receipt_no        text not null unique,
  status            text not null default 'posted' check (status in ('posted', 'reversed')),
  journal_entry_id  uuid not null references public.journal_entries (id),
  received_by       uuid,
  created_at        timestamptz not null default now(),
  reversed_at       timestamptz,
  reversed_by       uuid,
  reversed_reason   text
);
create index idx_payments_enrollment on public.payments (enrollment_id);
create index idx_payments_paid_on on public.payments (paid_on);

create table public.cash_transactions (
  id                uuid primary key default gen_random_uuid(),
  kind              text not null check (kind in ('expense', 'income')),
  txn_date          date not null,
  account_id        uuid not null references public.accounts (id),
  amount            numeric(12,2) not null check (amount > 0),
  mode              text not null check (mode in ('cash', 'upi', 'bank_transfer', 'cheque', 'card', 'other')),
  party             text,
  reference         text,
  notes             text,
  status            text not null default 'posted' check (status in ('posted', 'reversed')),
  journal_entry_id  uuid not null references public.journal_entries (id),
  created_by        uuid,
  created_at        timestamptz not null default now(),
  reversed_at       timestamptz,
  reversed_reason   text
);
create index idx_cash_txn_date on public.cash_transactions (txn_date);

-- ---------------------------------------------------------------- audit
create table public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid,
  table_name  text not null,
  row_id      text,
  action      text not null,
  old_row     jsonb,
  new_row     jsonb
);
create index idx_audit_at on public.audit_log (at desc);
create index idx_audit_table_row on public.audit_log (table_name, row_id);

-- ---------------------------------------------------------------- triggers
create function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger trg_students_touch before update on public.students
  for each row execute function private.touch_updated_at();

create function private.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_log (actor, table_name, row_id, action, old_row, new_row)
  values (
    auth.uid(), tg_table_name,
    coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id'),
    tg_op,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'school_settings', 'students', 'enrollments', 'student_documents',
    'fee_structure', 'fee_assessments', 'fee_discounts', 'fee_opening_balances',
    'payments', 'cash_transactions', 'accounts', 'fee_heads'
  ] loop
    execute format(
      'create trigger trg_audit after insert or update or delete on public.%I
         for each row execute function private.audit_row()', t);
  end loop;
end $$;

-- The books cannot be edited or deleted; mistakes are fixed with reversing entries.
create function private.block_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'Journal records cannot be changed or deleted. Post a reversing entry instead.';
end $$;

create trigger trg_entries_immutable before update or delete on public.journal_entries
  for each row execute function private.block_change();
create trigger trg_lines_immutable before update or delete on public.journal_lines
  for each row execute function private.block_change();

create function private.check_entry_balanced() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_dr numeric; v_cr numeric; v_n integer;
begin
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*)
    into v_dr, v_cr, v_n
    from public.journal_lines where entry_id = new.entry_id;
  if v_dr <> v_cr or v_n < 2 then
    raise exception 'Unbalanced journal entry % (debit %, credit %)', new.entry_id, v_dr, v_cr;
  end if;
  return null;
end $$;

create constraint trigger trg_journal_balanced after insert on public.journal_lines
  deferrable initially deferred
  for each row execute function private.check_entry_balanced();
