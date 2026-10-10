-- Al-Khair Academy ERP, release 1: access helpers, posting engine, fee and payment
-- functions, and reports. Every write to a money table goes through here.

-- ---------------------------------------------------------------- access helpers
create function public.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select role = 'owner' from public.profiles where id = auth.uid() and is_active), false)
$$;

create function public.can_manage_accounts() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select role in ('owner', 'accountant') from public.profiles where id = auth.uid() and is_active), false)
$$;

create function private.require_accounts() returns void
language plpgsql set search_path = '' as $$
begin
  if not public.can_manage_accounts() then
    raise exception 'You do not have permission to do this.' using errcode = '42501';
  end if;
end $$;

create function private.require_owner() returns void
language plpgsql set search_path = '' as $$
begin
  if not public.is_owner() then
    raise exception 'Only the owner can do this.' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------- posting engine
create function private.acc(p_code text) returns uuid
language plpgsql stable set search_path = '' as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts where code = p_code;
  if v_id is null then raise exception 'Account % does not exist', p_code; end if;
  return v_id;
end $$;

create function private.cash_account(p_mode text) returns uuid
language plpgsql stable set search_path = '' as $$
begin
  if p_mode = 'cash' then return private.acc('1010');
  elsif p_mode in ('upi', 'bank_transfer', 'cheque', 'card', 'other') then return private.acc('1020');
  end if;
  raise exception 'Unknown payment mode %', p_mode;
end $$;

-- p_lines: jsonb array of {account_id, debit, credit, narration}
create function private.post_journal(
  p_date date, p_memo text, p_source_type text, p_source_id uuid,
  p_lines jsonb, p_is_opening boolean default false
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_locked date;
  v_dr numeric; v_cr numeric;
begin
  select books_locked_until into v_locked from public.school_settings where id;
  if v_locked is not null and p_date <= v_locked then
    raise exception 'Books are locked up to %. An entry dated % cannot be posted.', v_locked, p_date;
  end if;

  select coalesce(sum(round(coalesce((x ->> 'debit')::numeric, 0), 2)), 0),
         coalesce(sum(round(coalesce((x ->> 'credit')::numeric, 0), 2)), 0)
    into v_dr, v_cr
    from jsonb_array_elements(p_lines) x;
  if v_dr <> v_cr or v_dr = 0 then
    raise exception 'Journal entry is not balanced (debit %, credit %)', v_dr, v_cr;
  end if;

  insert into public.journal_entries (id, entry_date, memo, source_type, source_id, is_opening, created_by)
  values (v_id, p_date, p_memo, p_source_type, p_source_id, p_is_opening, auth.uid());

  insert into public.journal_lines (entry_id, account_id, debit, credit, narration)
  select v_id, (x ->> 'account_id')::uuid,
         round(coalesce((x ->> 'debit')::numeric, 0), 2),
         round(coalesce((x ->> 'credit')::numeric, 0), 2),
         x ->> 'narration'
    from jsonb_array_elements(p_lines) x
   where round(coalesce((x ->> 'debit')::numeric, 0), 2) <> 0
      or round(coalesce((x ->> 'credit')::numeric, 0), 2) <> 0;

  return v_id;
end $$;

create function private.reverse_entry(p_entry uuid, p_memo text, p_date date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_locked date;
  v_orig public.journal_entries%rowtype;
begin
  select * into v_orig from public.journal_entries where id = p_entry;
  if not found then raise exception 'Journal entry not found'; end if;
  if exists (select 1 from public.journal_entries where reverses_entry_id = p_entry) then
    raise exception 'This entry has already been reversed';
  end if;
  select books_locked_until into v_locked from public.school_settings where id;
  if v_locked is not null and p_date <= v_locked then
    raise exception 'Books are locked up to %. A reversal dated % cannot be posted.', v_locked, p_date;
  end if;

  insert into public.journal_entries (id, entry_date, memo, source_type, source_id, reverses_entry_id, created_by)
  values (v_id, p_date, p_memo, 'reversal', v_orig.source_id, p_entry, auth.uid());

  insert into public.journal_lines (entry_id, account_id, debit, credit, narration)
  select v_id, account_id, credit, debit, narration
    from public.journal_lines where entry_id = p_entry;

  return v_id;
end $$;

-- ---------------------------------------------------------------- fee demand
-- Compares what the fee tables say the student owes with what is already posted
-- to the books, and posts only the difference.
create function private.sync_fee_demand(p_enr uuid, p_date date default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_date date := coalesce(p_date, current_date);
  v_recv uuid := private.acc('1100');
  v_conc uuid := private.acc('4900');
  v_open uuid := private.acc('3000');
  v_lines jsonb := '[]'::jsonb;
  r record;
  v_delta numeric; v_target numeric; v_posted numeric;
begin
  for r in
    select h.id as head_id, h.income_account_id,
           coalesce(a.amount, 0) as target, coalesce(l.amount_posted, 0) as posted
      from public.fee_heads h
      left join public.fee_assessments a on a.enrollment_id = p_enr and a.fee_head_id = h.id
      left join public.fee_posting_ledger l
             on l.enrollment_id = p_enr and l.kind = 'assessment' and l.fee_head_id = h.id
     where a.id is not null or l.id is not null
  loop
    v_delta := r.target - r.posted;
    if v_delta <> 0 then
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object('account_id', v_recv, 'debit', greatest(v_delta, 0), 'credit', greatest(-v_delta, 0)),
        jsonb_build_object('account_id', r.income_account_id, 'debit', greatest(-v_delta, 0), 'credit', greatest(v_delta, 0)));
      insert into public.fee_posting_ledger (enrollment_id, kind, fee_head_id, amount_posted)
      values (p_enr, 'assessment', r.head_id, r.target)
      on conflict (enrollment_id, kind, (coalesce(fee_head_id, '00000000-0000-0000-0000-000000000000'::uuid)))
      do update set amount_posted = excluded.amount_posted;
    end if;
  end loop;

  -- concessions (contra-income)
  select coalesce(sum(amount), 0) into v_target
    from public.fee_discounts where enrollment_id = p_enr and status = 'active';
  v_posted := coalesce((select amount_posted from public.fee_posting_ledger
                         where enrollment_id = p_enr and kind = 'concession'), 0);
  v_delta := v_target - v_posted;
  if v_delta <> 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id', v_conc, 'debit', greatest(v_delta, 0), 'credit', greatest(-v_delta, 0)),
      jsonb_build_object('account_id', v_recv, 'debit', greatest(-v_delta, 0), 'credit', greatest(v_delta, 0)));
    insert into public.fee_posting_ledger (enrollment_id, kind, fee_head_id, amount_posted)
    values (p_enr, 'concession', null, v_target)
    on conflict (enrollment_id, kind, (coalesce(fee_head_id, '00000000-0000-0000-0000-000000000000'::uuid)))
    do update set amount_posted = excluded.amount_posted;
  end if;

  -- opening dues carried from before the system
  v_target := coalesce((select amount from public.fee_opening_balances where enrollment_id = p_enr), 0);
  v_posted := coalesce((select amount_posted from public.fee_posting_ledger
                         where enrollment_id = p_enr and kind = 'opening'), 0);
  v_delta := v_target - v_posted;
  if v_delta <> 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id', v_recv, 'debit', greatest(v_delta, 0), 'credit', greatest(-v_delta, 0)),
      jsonb_build_object('account_id', v_open, 'debit', greatest(-v_delta, 0), 'credit', greatest(v_delta, 0)));
    insert into public.fee_posting_ledger (enrollment_id, kind, fee_head_id, amount_posted)
    values (p_enr, 'opening', null, v_target)
    on conflict (enrollment_id, kind, (coalesce(fee_head_id, '00000000-0000-0000-0000-000000000000'::uuid)))
    do update set amount_posted = excluded.amount_posted;
  end if;

  if jsonb_array_length(v_lines) > 0 then
    perform private.post_journal(v_date, 'Fee demand adjustment', 'fee_demand', p_enr, v_lines);
  end if;
end $$;

create function private.enrollment_balance(p_enr uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(case kind when 'concession' then -amount_posted else amount_posted end)
                     from public.fee_posting_ledger where enrollment_id = p_enr), 0)
       - coalesce((select sum(amount) from public.payments
                    where enrollment_id = p_enr and status = 'posted'), 0)
$$;

create function public.set_fee_assessment(
  p_enrollment uuid, p_fee_head uuid, p_amount numeric, p_date date default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  if p_amount is null or p_amount < 0 then raise exception 'Amount cannot be negative'; end if;
  insert into public.fee_assessments (enrollment_id, fee_head_id, amount)
  values (p_enrollment, p_fee_head, round(p_amount, 2))
  on conflict (enrollment_id, fee_head_id) do update set amount = excluded.amount;
  perform private.sync_fee_demand(p_enrollment, p_date);
  if private.enrollment_balance(p_enrollment) < 0 then
    raise exception 'This change would reduce the fee below the amount already paid';
  end if;
end $$;

create function public.apply_fee_structure(p_enrollment uuid, p_date date default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  insert into public.fee_assessments (enrollment_id, fee_head_id, amount)
  select e.id, fs.fee_head_id, fs.amount
    from public.enrollments e
    join public.fee_structure fs
      on fs.academic_year_id = e.academic_year_id and fs.class_id = e.class_id
   where e.id = p_enrollment
  on conflict (enrollment_id, fee_head_id) do nothing;
  perform private.sync_fee_demand(p_enrollment, p_date);
end $$;

create function public.apply_fee_structure_for_year(p_year uuid, p_date date default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  perform private.require_owner();
  for r in select id from public.enrollments where academic_year_id = p_year loop
    perform public.apply_fee_structure(r.id, p_date);
    n := n + 1;
  end loop;
  return n;
end $$;

create function public.add_fee_discount(
  p_enrollment uuid, p_amount numeric, p_reason text,
  p_fee_head uuid default null, p_approved_by text default null, p_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_gross numeric; v_disc numeric;
begin
  perform private.require_owner();
  if p_amount is null or p_amount <= 0 then raise exception 'Discount must be more than zero'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required for every discount'; end if;
  select coalesce(sum(amount), 0) into v_gross from public.fee_assessments where enrollment_id = p_enrollment;
  select coalesce(sum(amount), 0) into v_disc
    from public.fee_discounts where enrollment_id = p_enrollment and status = 'active';
  if v_disc + round(p_amount, 2) > v_gross then
    raise exception 'Total discount (%) cannot be more than the total fee (%)', v_disc + round(p_amount, 2), v_gross;
  end if;
  insert into public.fee_discounts (enrollment_id, fee_head_id, amount, reason, approved_by, created_by)
  values (p_enrollment, p_fee_head, round(p_amount, 2), p_reason, p_approved_by, auth.uid())
  returning id into v_id;
  perform private.sync_fee_demand(p_enrollment, p_date);
  return v_id;
end $$;

create function public.reverse_fee_discount(p_discount uuid, p_reason text, p_date date default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_enr uuid;
begin
  perform private.require_owner();
  update public.fee_discounts
     set status = 'reversed', reversed_at = now(), reversed_reason = p_reason
   where id = p_discount and status = 'active'
  returning enrollment_id into v_enr;
  if v_enr is null then raise exception 'Active discount not found'; end if;
  perform private.sync_fee_demand(v_enr, p_date);
  if private.enrollment_balance(v_enr) < 0 then
    raise exception 'Reversing this discount is not possible because the fee has been overpaid';
  end if;
end $$;

create function public.set_opening_fee_balance(
  p_enrollment uuid, p_amount numeric, p_note text default null, p_date date default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  insert into public.fee_opening_balances (enrollment_id, amount, note)
  values (p_enrollment, round(p_amount, 2), p_note)
  on conflict (enrollment_id) do update set amount = excluded.amount, note = excluded.note;
  perform private.sync_fee_demand(p_enrollment, p_date);
end $$;

-- ---------------------------------------------------------------- payments
create function public.record_payment(
  p_enrollment uuid, p_amount numeric, p_mode text,
  p_reference text default null, p_paid_on date default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_date date := coalesce(p_paid_on, current_date);
  v_amount numeric := round(p_amount, 2);
  v_year uuid; v_label text; v_no integer; v_receipt text;
  v_balance numeric; v_entry uuid; v_id uuid := gen_random_uuid();
begin
  perform private.require_accounts();
  if v_amount is null or v_amount <= 0 then raise exception 'Payment must be more than zero'; end if;

  select academic_year_id into v_year from public.enrollments where id = p_enrollment for update;
  if not found then raise exception 'Enrollment not found'; end if;

  perform private.sync_fee_demand(p_enrollment, v_date);
  v_balance := private.enrollment_balance(p_enrollment);
  if v_amount > v_balance then
    raise exception 'Payment of % is more than the balance due of %', v_amount, v_balance;
  end if;

  insert into public.receipt_counters (academic_year_id, last_no) values (v_year, 1)
  on conflict (academic_year_id) do update set last_no = public.receipt_counters.last_no + 1
  returning last_no into v_no;
  select label into v_label from public.academic_years where id = v_year;
  v_receipt := 'AK/' || v_label || '/' || lpad(v_no::text, 6, '0');

  v_entry := private.post_journal(v_date, 'Fee receipt ' || v_receipt, 'payment', v_id, jsonb_build_array(
    jsonb_build_object('account_id', private.cash_account(p_mode), 'debit', v_amount, 'credit', 0),
    jsonb_build_object('account_id', private.acc('1100'), 'debit', 0, 'credit', v_amount)));

  insert into public.payments (id, enrollment_id, amount, mode, reference, paid_on, receipt_no, journal_entry_id, received_by)
  values (v_id, p_enrollment, v_amount, p_mode, p_reference, v_date, v_receipt, v_entry, auth.uid());

  return jsonb_build_object('payment_id', v_id, 'receipt_no', v_receipt, 'balance_after', v_balance - v_amount);
end $$;

create function public.reverse_payment(p_payment uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_p public.payments%rowtype;
begin
  perform private.require_owner();
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into v_p from public.payments where id = p_payment and status = 'posted' for update;
  if not found then raise exception 'Posted payment not found'; end if;
  perform private.reverse_entry(v_p.journal_entry_id,
    'Reversal of receipt ' || v_p.receipt_no || ': ' || p_reason, current_date);
  update public.payments
     set status = 'reversed', reversed_at = now(), reversed_by = auth.uid(), reversed_reason = p_reason
   where id = p_payment;
end $$;

-- ---------------------------------------------------------------- other income and expenses
create function public.record_cash_transaction(
  p_kind text, p_account_code text, p_amount numeric, p_mode text,
  p_txn_date date default null, p_party text default null,
  p_reference text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_date date := coalesce(p_txn_date, current_date);
  v_amount numeric := round(p_amount, 2);
  v_acc public.accounts%rowtype;
  v_id uuid := gen_random_uuid();
  v_entry uuid; v_cash uuid;
begin
  perform private.require_accounts();
  if v_amount is null or v_amount <= 0 then raise exception 'Amount must be more than zero'; end if;
  select * into v_acc from public.accounts where code = p_account_code and is_active;
  if not found then raise exception 'Account % not found', p_account_code; end if;
  if p_kind = 'expense' and v_acc.type <> 'expense' then
    raise exception 'Account % is not an expense account', p_account_code;
  elsif p_kind = 'income' and v_acc.type <> 'income' then
    raise exception 'Account % is not an income account', p_account_code;
  elsif p_kind not in ('expense', 'income') then
    raise exception 'Kind must be expense or income';
  end if;
  v_cash := private.cash_account(p_mode);

  if p_kind = 'expense' then
    v_entry := private.post_journal(v_date, coalesce(p_party, v_acc.name), 'cash_transaction', v_id, jsonb_build_array(
      jsonb_build_object('account_id', v_acc.id, 'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_cash, 'debit', 0, 'credit', v_amount)));
  else
    v_entry := private.post_journal(v_date, coalesce(p_party, v_acc.name), 'cash_transaction', v_id, jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', v_amount, 'credit', 0),
      jsonb_build_object('account_id', v_acc.id, 'debit', 0, 'credit', v_amount)));
  end if;

  insert into public.cash_transactions
    (id, kind, txn_date, account_id, amount, mode, party, reference, notes, journal_entry_id, created_by)
  values (v_id, p_kind, v_date, v_acc.id, v_amount, p_mode, p_party, p_reference, p_notes, v_entry, auth.uid());
  return v_id;
end $$;

create function public.reverse_cash_transaction(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_t public.cash_transactions%rowtype;
begin
  perform private.require_owner();
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into v_t from public.cash_transactions where id = p_id and status = 'posted' for update;
  if not found then raise exception 'Posted transaction not found'; end if;
  perform private.reverse_entry(v_t.journal_entry_id, 'Reversal: ' || p_reason, current_date);
  update public.cash_transactions
     set status = 'reversed', reversed_at = now(), reversed_reason = p_reason where id = p_id;
end $$;

-- ---------------------------------------------------------------- owner-only book controls
-- p_lines: [{"account_code":"1010","debit":50000}, {"account_code":"2200","credit":10000}]
-- The difference is balanced against 3000 Opening balance equity.
create function public.set_opening_balances(p_as_of date, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_lines jsonb := '[]'::jsonb;
  x jsonb; v_dr numeric := 0; v_cr numeric := 0; v_diff numeric;
begin
  perform private.require_owner();
  if exists (select 1 from public.journal_entries e
              where e.source_type = 'opening_balances'
                and not exists (select 1 from public.journal_entries r where r.reverses_entry_id = e.id)) then
    raise exception 'Opening balances already exist. Reverse them first with reverse_manual_entry.';
  end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', private.acc(x ->> 'account_code'),
      'debit', coalesce((x ->> 'debit')::numeric, 0),
      'credit', coalesce((x ->> 'credit')::numeric, 0));
    v_dr := v_dr + round(coalesce((x ->> 'debit')::numeric, 0), 2);
    v_cr := v_cr + round(coalesce((x ->> 'credit')::numeric, 0), 2);
  end loop;
  v_diff := v_dr - v_cr;
  if v_diff > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', private.acc('3000'), 'debit', 0, 'credit', v_diff);
  elsif v_diff < 0 then
    v_lines := v_lines || jsonb_build_object('account_id', private.acc('3000'), 'debit', -v_diff, 'credit', 0);
  end if;
  return private.post_journal(p_as_of, 'Opening balances', 'opening_balances', null, v_lines, true);
end $$;

-- Adjustments such as depreciation, bank charges or corrections.
create function public.post_manual_entry(p_date date, p_memo text, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_lines jsonb := '[]'::jsonb; x jsonb;
begin
  perform private.require_owner();
  if coalesce(trim(p_memo), '') = '' then raise exception 'A memo is required'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', private.acc(x ->> 'account_code'),
      'debit', coalesce((x ->> 'debit')::numeric, 0),
      'credit', coalesce((x ->> 'credit')::numeric, 0),
      'narration', x ->> 'narration');
  end loop;
  return private.post_journal(p_date, p_memo, 'manual', null, v_lines);
end $$;

create function public.reverse_manual_entry(p_entry uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_type text;
begin
  perform private.require_owner();
  select source_type into v_type from public.journal_entries where id = p_entry;
  if v_type is null or v_type not in ('manual', 'opening_balances') then
    raise exception 'Only manual and opening-balance entries can be reversed here';
  end if;
  return private.reverse_entry(p_entry, 'Reversal: ' || coalesce(p_reason, ''), current_date);
end $$;

create function public.set_books_locked_until(p_date date) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  update public.school_settings set books_locked_until = p_date, updated_at = now() where id;
end $$;

-- ---------------------------------------------------------------- reports (run with the caller's permissions)
create function public.fn_trial_balance(p_as_of date default current_date)
returns table (code text, name text, type text, debit numeric, credit numeric)
language sql stable set search_path = '' as $$
  select a.code, a.name, a.type,
         case when sum(l.debit - l.credit) > 0 then sum(l.debit - l.credit) else 0 end,
         case when sum(l.debit - l.credit) < 0 then -sum(l.debit - l.credit) else 0 end
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
   where e.entry_date <= p_as_of
   group by a.code, a.name, a.type
  having sum(l.debit - l.credit) <> 0
   order by a.code
$$;

create function public.fn_profit_loss(p_from date, p_to date)
returns table (section text, code text, name text, amount numeric)
language sql stable set search_path = '' as $$
  select a.type, a.code, a.name,
         case a.type when 'income' then sum(l.credit - l.debit) else sum(l.debit - l.credit) end
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
   where a.type in ('income', 'expense') and e.entry_date between p_from and p_to
   group by a.type, a.code, a.name
  having sum(l.debit - l.credit) <> 0
   order by a.type desc, a.code
$$;

create function public.fn_balance_sheet(p_as_of date default current_date)
returns table (section text, code text, name text, amount numeric)
language sql stable set search_path = '' as $$
  select a.type, a.code, a.name,
         case a.type when 'asset' then sum(l.debit - l.credit) else sum(l.credit - l.debit) end
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
   where a.type in ('asset', 'liability', 'equity') and e.entry_date <= p_as_of
   group by a.type, a.code, a.name
  having sum(l.debit - l.credit) <> 0
  union all
  select 'equity', '3999', 'Surplus / (deficit) to date',
         coalesce(sum(l.credit - l.debit), 0)
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
   where a.type in ('income', 'expense') and e.entry_date <= p_as_of
  order by 1, 2
$$;

-- Do the fee ledger in the books and the per-student balances agree?
create function public.fn_fee_subledger_check()
returns table (gl_balance numeric, student_total numeric, difference numeric)
language sql stable set search_path = '' as $$
  with gl as (
    select coalesce(sum(l.debit - l.credit), 0) as bal
      from public.journal_lines l join public.accounts a on a.id = l.account_id
     where a.code = '1100'),
  sub as (
    select coalesce((select sum(case kind when 'concession' then -amount_posted else amount_posted end)
                       from public.fee_posting_ledger), 0)
         - coalesce((select sum(amount) from public.payments where status = 'posted'), 0) as bal)
  select gl.bal, sub.bal, gl.bal - sub.bal from gl, sub
$$;

-- ---------------------------------------------------------------- views (caller's permissions apply)
create view public.v_student_fee_summary with (security_invoker = true) as
select e.id as enrollment_id, e.academic_year_id, y.label as academic_year,
       s.id as student_id, s.admission_no, s.full_name, c.name as class_name, c.sort_order,
       coalesce(sum(l.amount_posted) filter (where l.kind = 'assessment'), 0) as gross_fee,
       coalesce(sum(l.amount_posted) filter (where l.kind = 'concession'), 0) as discount,
       coalesce(sum(l.amount_posted) filter (where l.kind = 'opening'), 0)    as previous_dues,
       coalesce((select sum(p.amount) from public.payments p
                  where p.enrollment_id = e.id and p.status = 'posted'), 0)   as paid,
       coalesce(sum(case l.kind when 'concession' then -l.amount_posted else l.amount_posted end), 0)
         - coalesce((select sum(p.amount) from public.payments p
                      where p.enrollment_id = e.id and p.status = 'posted'), 0) as balance
  from public.enrollments e
  join public.students s on s.id = e.student_id
  join public.classes c on c.id = e.class_id
  join public.academic_years y on y.id = e.academic_year_id
  left join public.fee_posting_ledger l on l.enrollment_id = e.id
 group by e.id, y.label, s.id, c.name, c.sort_order;

create view public.v_student_missing_documents with (security_invoker = true) as
select s.id as student_id, s.admission_no, s.full_name, c.name as class_name,
       dt.id as document_type_id, dt.name as document_name
  from public.enrollments e
  join public.academic_years y on y.id = e.academic_year_id and y.is_current
  join public.students s on s.id = e.student_id and s.status = 'active'
  join public.classes c on c.id = e.class_id
  join public.document_types dt on dt.is_active and c.sort_order >= dt.required_from_order
 where not exists (
   select 1 from public.student_documents d
    where d.student_id = s.id and d.document_type_id = dt.id
      and d.status in ('received', 'not_applicable'));

create view public.v_fee_collection_monthly with (security_invoker = true) as
select month, sum(amount) as amount
  from (
    select date_trunc('month', paid_on)::date as month, amount
      from public.payments where status = 'posted'
    union all
    select month, amount from public.fee_collection_history
  ) t
 group by month;

create view public.v_monthly_income_expense with (security_invoker = true) as
select date_trunc('month', e.entry_date)::date as month,
       coalesce(sum(l.credit - l.debit) filter (where a.type = 'income'), 0)  as income,
       coalesce(sum(l.debit - l.credit) filter (where a.type = 'expense'), 0) as expense
  from public.journal_lines l
  join public.journal_entries e on e.id = l.entry_id
  join public.accounts a on a.id = l.account_id
 where a.type in ('income', 'expense')
 group by 1;
