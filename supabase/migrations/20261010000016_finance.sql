-- Finance tab: fixed assets with depreciation, ledger and cash-flow summaries, saved assumptions.
create table if not exists public.fixed_assets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null check (category in ('furniture','equipment','computers','vehicle','building','land','other')),
  purchase_date date not null,
  cost numeric(14,2) not null check (cost > 0),
  salvage_value numeric(14,2) not null default 0 check (salvage_value >= 0),
  life_years numeric(5,1) check (life_years is null or life_years > 0),
  asset_account_code text not null,
  journal_entry_id uuid references public.journal_entries(id),
  status text not null default 'active' check (status in ('active','disposed')),
  notes text,
  created_at timestamptz not null default now()
);
create table if not exists public.asset_dep_runs (
  month date primary key,
  amount numeric(14,2) not null,
  journal_entry_id uuid references public.journal_entries(id),
  created_at timestamptz not null default now()
);
create table if not exists public.finance_settings (id boolean primary key default true check (id), data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.fixed_assets enable row level security;
alter table public.asset_dep_runs enable row level security;
alter table public.finance_settings enable row level security;
create policy fa_read on public.fixed_assets for select using (public.can_manage_accounts());
create policy dr_read on public.asset_dep_runs for select using (public.can_manage_accounts());
create policy fs_all on public.finance_settings for all using (public.can_manage_accounts()) with check (public.can_manage_accounts());

create or replace function public.asset_add(p_name text, p_category text, p_date date, p_cost numeric, p_life numeric, p_salvage numeric, p_mode text, p_notes text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_code text; v_entry uuid;
begin
  if not public.can_manage_accounts() then raise exception 'You do not have permission to do this.' using errcode = '42501'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the asset name'; end if;
  if p_cost is null or p_cost <= 0 then raise exception 'Cost must be more than zero'; end if;
  if p_category <> 'land' and (p_life is null or p_life <= 0) then raise exception 'Enter the useful life in years'; end if;
  if coalesce(p_salvage, 0) >= p_cost then raise exception 'Residual value must be less than the cost'; end if;
  v_code := case when p_category in ('building','land') then '1510' else '1500' end;
  v_entry := private.post_journal(p_date, 'Asset purchase - ' || trim(p_name), 'asset', v_id, jsonb_build_array(
    jsonb_build_object('account_id', private.acc(v_code), 'debit', p_cost, 'credit', 0),
    jsonb_build_object('account_id', case when p_mode = 'opening' then private.acc('3000') else private.cash_account(p_mode) end, 'debit', 0, 'credit', p_cost)));
  insert into public.fixed_assets(id, name, category, purchase_date, cost, salvage_value, life_years, asset_account_code, journal_entry_id, notes)
  values (v_id, trim(p_name), p_category, p_date, p_cost, coalesce(p_salvage, 0), case when p_category = 'land' then null else p_life end, v_code, v_entry, nullif(trim(coalesce(p_notes, '')), ''));
  return v_id;
end $$;

-- One straight-line depreciation entry per month for all active assets (dated the last day of the month).
create or replace function public.asset_depreciation_run(p_month date) returns numeric
language plpgsql security definer set search_path = '' as $$
declare v_m date := date_trunc('month', p_month)::date; v_end date; v_amt numeric; v_entry uuid;
begin
  if not public.can_manage_accounts() then raise exception 'You do not have permission to do this.' using errcode = '42501'; end if;
  v_end := (v_m + interval '1 month - 1 day')::date;
  if v_end >= (date_trunc('month', current_date) + interval '1 month')::date then raise exception 'You can only post depreciation for a finished month'; end if;
  if exists (select 1 from public.asset_dep_runs where month = v_m) then raise exception 'Depreciation for % is already posted', to_char(v_m, 'Mon YYYY'); end if;
  select coalesce(sum(round((cost - salvage_value) / (life_years * 12), 2)), 0) into v_amt from public.fixed_assets
   where status = 'active' and life_years is not null and date_trunc('month', purchase_date) <= v_m
     and v_m < (date_trunc('month', purchase_date) + (life_years * 12) * interval '1 month');
  if v_amt <= 0 then raise exception 'There is nothing to depreciate for this month'; end if;
  v_entry := private.post_journal(v_end, 'Depreciation ' || to_char(v_m, 'Mon YYYY'), 'depreciation', null, jsonb_build_array(
    jsonb_build_object('account_id', private.acc('5120'), 'debit', v_amt, 'credit', 0),
    jsonb_build_object('account_id', private.acc('1590'), 'debit', 0, 'credit', v_amt)));
  insert into public.asset_dep_runs(month, amount, journal_entry_id) values (v_m, v_amt, v_entry);
  return v_amt;
end $$;

-- Totals per month and account from the books (for health, FCFF and forecast).
create or replace function public.fin_ledger() returns table(month date, code text, name text, type text, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.can_manage_accounts() then raise exception 'You do not have permission to do this.' using errcode = '42501'; end if;
  return query select date_trunc('month', e.entry_date)::date, a.code, a.name, a.type, sum(l.debit), sum(l.credit)
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
    group by 1, a.code, a.name, a.type order by 1, a.code;
end $$;

-- Cash and bank movement per month, grouped by what the other side of the entry was.
create or replace function public.fin_cashflow() returns table(month date, code text, amount numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.can_manage_accounts() then raise exception 'You do not have permission to do this.' using errcode = '42501'; end if;
  return query
  with cash as (
    select l.entry_id, e.entry_date, (l.debit - l.credit) as amt from public.journal_lines l
      join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id where a.code in ('1010','1020')),
  ctr as (
    select c.entry_date, c.amt, (select a2.code from public.journal_lines l2 join public.accounts a2 on a2.id = l2.account_id
        where l2.entry_id = c.entry_id and a2.code not in ('1010','1020') order by greatest(l2.debit, l2.credit) desc limit 1) as code from cash c)
  select date_trunc('month', entry_date)::date, ctr.code, sum(amt) from ctr group by 1, 2 order by 1, 2;
end $$;

revoke all on function public.asset_add(text,text,date,numeric,numeric,numeric,text,text), public.asset_depreciation_run(date), public.fin_ledger(), public.fin_cashflow() from public, anon;
grant execute on function public.asset_add(text,text,date,numeric,numeric,numeric,text,text), public.asset_depreciation_run(date), public.fin_ledger(), public.fin_cashflow() to authenticated;
