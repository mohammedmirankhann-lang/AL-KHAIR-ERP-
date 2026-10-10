-- One row per past year: fees received and expenses, as kept in the school's yearly summary sheet.
create table public.yearly_finance_history (
  year_label     text primary key,                       -- e.g. 2018-19
  fees_received  numeric(14,2) not null check (fees_received >= 0),
  expenses       numeric(14,2) not null check (expenses >= 0),
  source         text not null default 'import'
);
alter table public.yearly_finance_history enable row level security;
grant select on public.yearly_finance_history to authenticated;
create policy accounts_read on public.yearly_finance_history for select to authenticated
  using (public.can_manage_accounts());

insert into public.yearly_finance_history (year_label, fees_received, expenses) values
  ('2018-19',  795310,  650907),
  ('2019-20',  816000, 1001630),
  ('2020-21',  337897,  178418),
  ('2021-22',  767310,  544578),
  ('2022-23', 2858155, 2373876),
  ('2023-24', 4183032, 3945455),
  ('2024-25', 4490003, 3452647),
  ('2025-26', 5018115, 4178885);
