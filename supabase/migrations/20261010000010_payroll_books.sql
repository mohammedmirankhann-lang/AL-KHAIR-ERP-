-- Salary posting to the books + staff bank details (for bulk transfer file)
insert into accounts(code,name,type,is_system) values ('2110','Staff holdback payable','liability',false) on conflict (code) do nothing;

alter table payroll_lines add column if not exists journal_entry_id uuid references journal_entries(id);
alter table staff add column if not exists bank_account_no text, add column if not exists bank_ifsc text, add column if not exists bank_account_name text;

-- Posts one paid payroll line: Dr Salaries (net + holdback), Cr Bank/Cash (net), Cr Staff holdback payable (holdback).
-- Dated the last day of the salary month so the P&L shows the cost in the month it belongs to.
create or replace function private.payroll_post_line(p_line uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare l public.payroll_lines%rowtype; v_entry uuid; v_gross numeric; v_date date; v_name text; v_cash uuid;
begin
  select * into l from public.payroll_lines where id = p_line for update;
  if not found then raise exception 'Payroll line not found'; end if;
  if l.status <> 'paid' or l.journal_entry_id is not null then return l.journal_entry_id; end if;
  v_gross := round(l.net_pay + l.holdback, 2);
  if v_gross <= 0 then return null; end if;
  v_date := (date_trunc('month', l.month) + interval '1 month - 1 day')::date;
  select full_name into v_name from public.staff where id = l.staff_id;
  v_cash := private.cash_account(case when l.pay_mode = 'cash' then 'cash' else 'bank_transfer' end);
  v_entry := private.post_journal(v_date, 'Salary ' || to_char(l.month, 'Mon YYYY') || ' - ' || coalesce(v_name, ''), 'payroll', l.id, jsonb_build_array(
    jsonb_build_object('account_id', private.acc('5010'), 'debit', v_gross, 'credit', 0),
    jsonb_build_object('account_id', v_cash, 'debit', 0, 'credit', l.net_pay),
    jsonb_build_object('account_id', private.acc('2110'), 'debit', 0, 'credit', l.holdback)));
  update public.payroll_lines set journal_entry_id = v_entry where id = l.id;
  return v_entry;
end $$;

create or replace function public.payroll_mark_paid(p_line uuid, p_paid_on date, p_mode text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_manage_accounts() then raise exception 'You do not have permission to do this.'; end if;
  update public.payroll_lines set status = 'paid', paid_on = p_paid_on, pay_mode = p_mode where id = p_line and status = 'draft';
  if not found then raise exception 'Already paid or not found'; end if;
  perform private.payroll_post_line(p_line);
end $$;

-- Posts every paid line that is not in the books yet (used once for the imported Apr-Sep history).
create or replace function public.payroll_post_pending() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  if not public.can_manage_accounts() then raise exception 'You do not have permission to do this.'; end if;
  for r in select id from public.payroll_lines where status = 'paid' and journal_entry_id is null order by month loop
    if private.payroll_post_line(r.id) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

revoke all on function public.payroll_mark_paid(uuid, date, text), public.payroll_post_pending() from public, anon;
grant execute on function public.payroll_mark_paid(uuid, date, text), public.payroll_post_pending() to authenticated;
revoke all on function private.payroll_post_line(uuid) from public, anon, authenticated;
