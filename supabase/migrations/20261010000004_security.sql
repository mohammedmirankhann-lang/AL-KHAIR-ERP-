-- Al-Khair Academy ERP, release 1: row-level security and privileges.
-- Rule of the house: nobody who is not signed in sees anything, and money tables
-- can only be written through the functions in migration 0002.

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- Group A: owner reads and writes, accountant reads.
do $$
declare t text;
begin
  foreach t in array array[
    'academic_years', 'classes', 'sections', 'document_types', 'students', 'enrollments',
    'student_documents', 'accounts', 'fee_heads', 'fee_structure', 'fee_collection_history',
    'school_settings', 'profiles'
  ] loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format(
      'create policy owner_all on public.%I for all to authenticated
         using (public.is_owner()) with check (public.is_owner())', t);
    execute format(
      'create policy accounts_read on public.%I for select to authenticated
         using (public.can_manage_accounts())', t);
  end loop;
end $$;

create policy self_read on public.profiles for select to authenticated using (id = auth.uid());

-- Group B: books and fee ledgers. Read only; changes come from functions.
do $$
declare t text;
begin
  foreach t in array array[
    'journal_entries', 'journal_lines', 'payments', 'receipt_counters', 'fee_assessments',
    'fee_discounts', 'fee_opening_balances', 'fee_posting_ledger', 'cash_transactions'
  ] loop
    execute format('grant select on public.%I to authenticated', t);
    execute format(
      'create policy accounts_read on public.%I for select to authenticated
         using (public.can_manage_accounts())', t);
  end loop;
end $$;

-- Group C: audit trail, owner only.
grant select on public.audit_log to authenticated;
create policy owner_read on public.audit_log for select to authenticated using (public.is_owner());

-- Views run with the caller's rights, so the policies above apply to them too.
grant select on public.v_student_fee_summary, public.v_student_missing_documents,
                public.v_fee_collection_monthly, public.v_monthly_income_expense to authenticated;

-- Functions the app may call. Everything else stays closed.
grant execute on function
  public.is_owner(),
  public.can_manage_accounts(),
  public.set_fee_assessment(uuid, uuid, numeric, date),
  public.apply_fee_structure(uuid, date),
  public.apply_fee_structure_for_year(uuid, date),
  public.add_fee_discount(uuid, numeric, text, uuid, text, date),
  public.reverse_fee_discount(uuid, text, date),
  public.set_opening_fee_balance(uuid, numeric, text, date),
  public.record_payment(uuid, numeric, text, text, date),
  public.reverse_payment(uuid, text),
  public.record_cash_transaction(text, text, numeric, text, date, text, text, text),
  public.reverse_cash_transaction(uuid, text),
  public.set_opening_balances(date, jsonb),
  public.post_manual_entry(date, text, jsonb),
  public.reverse_manual_entry(uuid, text),
  public.set_books_locked_until(date),
  public.fn_trial_balance(date),
  public.fn_profit_loss(date, date),
  public.fn_balance_sheet(date),
  public.fn_fee_subledger_check()
to authenticated;

-- Guard rail: the migration fails if any table in public is left without row-level security.
do $$
declare t text;
begin
  select c.relname into t
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
   limit 1;
  if t is not null then
    raise exception 'Table public.% has no row-level security', t;
  end if;
end $$;
