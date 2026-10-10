-- Two more fee heads (Activity, Computer) with their own income accounts, and a read-only
-- table that keeps last year's fee register per student for year-on-year comparison.

insert into public.accounts (code, name, type, is_system) values
  ('4070', 'Activity fees', 'income', true),
  ('4080', 'Computer fees', 'income', true)
on conflict (code) do nothing;

insert into public.fee_heads (code, name, income_account_id)
select h.code, h.name, a.id
  from (values ('ACTIVITY', 'Activity fee', '4070'), ('COMPUTER', 'Computer fee', '4080')) as h(code, name, acc)
  join public.accounts a on a.code = h.acc
on conflict (code) do nothing;

create table public.fee_year_history (
  id            uuid primary key default gen_random_uuid(),
  year_label    text not null,
  admission_no  text,             -- scholar no. as written in that year's register (may be blank)
  student_id    uuid references public.students (id) on delete set null,   -- set when the student is still on roll
  student_name  text not null,
  class_name    text not null,
  seat_type     text,             -- RTE / RTI where the register says so
  gross_fee     numeric(12,2) not null,
  discount      numeric(12,2) not null default 0,
  net_fee       numeric(12,2) not null,
  paid          numeric(12,2) not null default 0,
  due           numeric(12,2) not null default 0,
  source        text not null default 'import'
);
create index idx_fee_year_history_year on public.fee_year_history (year_label);
create index idx_fee_year_history_student on public.fee_year_history (student_id);

alter table public.fee_year_history enable row level security;
grant select on public.fee_year_history to authenticated;
create policy accounts_read on public.fee_year_history for select to authenticated
  using (public.can_manage_accounts());
