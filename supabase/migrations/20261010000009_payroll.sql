-- Payroll, following the school's salary sheet rules (checked against April to September 2026-27):
--   per day   = monthly salary / days in the month
--   paid days = days present + paid holidays + weekly off (Sunday). Leave and absence are unpaid.
--   half day  = 3 hours cut at hourly rate (per day / working hours)
--   holdback  = a percentage of the full monthly salary, for staff marked with one.

alter table staff
  add column if not exists shift_start time,
  add column if not exists shift_end time,
  add column if not exists work_hours numeric(3,1),
  add column if not exists pay_mode text check (pay_mode in ('online','cash')),
  add column if not exists holdback_pct numeric(4,1) not null default 0 check (holdback_pct between 0 and 100);

create table if not exists payroll_lines (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id) on delete restrict,
  month date not null check (month = date_trunc('month', month)::date),
  salary numeric(10,2) not null,
  days_in_month integer not null,
  paid_days numeric(4,1) not null,
  unpaid_days numeric(4,1) not null default 0,
  half_days integer not null default 0,
  per_day numeric(10,2) not null,
  hourly numeric(10,2) not null,
  earned numeric(10,2) not null,
  half_day_cut numeric(10,2) not null default 0,
  holdback numeric(10,2) not null default 0,
  adjustment numeric(10,2) not null default 0,
  adjustment_note text,
  net_pay numeric(10,2) not null,
  pay_mode text check (pay_mode in ('online','cash')),
  status text not null default 'draft' check (status in ('draft','paid')),
  paid_on date,
  source text not null default 'erp' check (source in ('erp','excel')),
  note text,
  created_at timestamptz not null default now(),
  unique (staff_id, month)
);
alter table payroll_lines enable row level security;
create policy owner_all on payroll_lines for all using (is_owner()) with check (is_owner());
create policy self_read on payroll_lines for select using (status = 'paid' and staff_id in (select id from staff where user_id = auth.uid()));

-- Live calculation from the ERP's own attendance. Nothing is saved.
create or replace function public.payroll_calc(p_month date)
returns table(staff_id uuid, full_name text, designation text, salary numeric, days_in_month int, paid_days numeric,
              unpaid_days numeric, half_days int, per_day numeric, hourly numeric, earned numeric, half_day_cut numeric,
              holdback numeric, net_pay numeric, pay_mode text)
language sql stable security invoker set search_path = '' as $$
with m as (select date_trunc('month', p_month)::date d0),
     bounds as (select d0, (d0 + interval '1 month - 1 day')::date d1, extract(day from (d0 + interval '1 month - 1 day'))::int n,
                       (now() at time zone 'Asia/Kolkata')::date today from m),
     cfg as (select coalesce((select weekly_off from public.school_settings limit 1), '{0}') wo,
                    coalesce((select paid_leaves_per_month from public.school_settings limit 1), 0) pl),
     st as (select s.* from public.staff s, bounds b
            where s.monthly_salary is not null and s.monthly_salary > 0
              and (s.joined_on is null or s.joined_on <= b.d1)
              and (s.status = 'active' or exists (select 1 from public.staff_attendance a where a.staff_id = s.id and a.work_date between b.d0 and b.d1))),
     grid as (
       select s.id sid, d.dt,
         case
           when s.joined_on is not null and d.dt < s.joined_on then 'x'
           when a.status in ('present','late','paid_leave') then 'P'
           when a.status = 'half_day' then 'H'
           when a.status in ('unpaid_leave','absent') then 'L'
           when (select wo from cfg) @> array[extract(dow from d.dt)::int] or exists (select 1 from public.school_holidays h where h.holiday_on = d.dt) then 'R'
           when d.dt > (select today from bounds) then 'P'
           else 'L' end code
       from st s cross join bounds b
       cross join lateral generate_series(b.d0, b.d1, interval '1 day') g(ts)
       cross join lateral (select g.ts::date dt) d
       left join public.staff_attendance a on a.staff_id = s.id and a.work_date = d.dt),
     agg as (select sid, count(*) filter (where code = 'x') nx, count(*) filter (where code = 'L') nl, count(*) filter (where code = 'H') nh from grid group by sid)
select s.id, s.full_name, s.designation, s.monthly_salary, b.n,
       (b.n - ag.nx - greatest(0, ag.nl - (select pl from cfg)))::numeric,
       greatest(0, ag.nl - (select pl from cfg))::numeric, ag.nh::int,
       round(s.monthly_salary / b.n, 2),
       round(s.monthly_salary / b.n / coalesce(nullif(s.work_hours, 0), 6), 2),
       round(s.monthly_salary / b.n * (b.n - ag.nx - greatest(0, ag.nl - (select pl from cfg))), 0),
       round(3 * ag.nh * s.monthly_salary / b.n / coalesce(nullif(s.work_hours, 0), 6), 0),
       round(s.monthly_salary * s.holdback_pct / 100, 0),
       round(s.monthly_salary / b.n * (b.n - ag.nx - greatest(0, ag.nl - (select pl from cfg)))
             - 3 * ag.nh * s.monthly_salary / b.n / coalesce(nullif(s.work_hours, 0), 6)
             - s.monthly_salary * s.holdback_pct / 100, 0),
       s.pay_mode
from st s join agg ag on ag.sid = s.id cross join bounds b
order by s.full_name
$$;

-- Saves the calculation as draft payslips. Paid months are never touched.
create or replace function public.payroll_generate(p_month date)
returns integer language plpgsql security invoker set search_path = '' as $$
declare n integer;
begin
  if not public.is_owner() then raise exception 'Only the owner can run payroll'; end if;
  with c as (select * from public.payroll_calc(p_month)),
  up as (
    insert into public.payroll_lines(staff_id, month, salary, days_in_month, paid_days, unpaid_days, half_days, per_day, hourly, earned, half_day_cut, holdback, net_pay, pay_mode, source)
    select staff_id, date_trunc('month', p_month)::date, salary, days_in_month, paid_days, unpaid_days, half_days, per_day, hourly, earned, half_day_cut, holdback, net_pay, pay_mode, 'erp' from c
    on conflict (staff_id, month) do update set
      salary = excluded.salary, days_in_month = excluded.days_in_month, paid_days = excluded.paid_days, unpaid_days = excluded.unpaid_days,
      half_days = excluded.half_days, per_day = excluded.per_day, hourly = excluded.hourly, earned = excluded.earned,
      half_day_cut = excluded.half_day_cut, holdback = excluded.holdback, net_pay = excluded.earned - excluded.half_day_cut - excluded.holdback + public.payroll_lines.adjustment,
      pay_mode = coalesce(public.payroll_lines.pay_mode, excluded.pay_mode)
    where public.payroll_lines.status = 'draft'
    returning 1)
  select count(*) into n from up;
  return n;
end $$;

create or replace function public.payroll_mark_paid(p_line uuid, p_paid_on date, p_mode text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Only the owner can pay salaries'; end if;
  update public.payroll_lines set status = 'paid', paid_on = p_paid_on, pay_mode = p_mode where id = p_line and status = 'draft';
  if not found then raise exception 'Already paid or not found'; end if;
end $$;

revoke all on function public.payroll_calc(date), public.payroll_generate(date), public.payroll_mark_paid(uuid, date, text) from public, anon;
grant execute on function public.payroll_calc(date), public.payroll_generate(date), public.payroll_mark_paid(uuid, date, text) to authenticated;

-- Punch uses the person's own timings when they are set.
create or replace function public.staff_punch(p_lat double precision, p_lng double precision, p_accuracy double precision default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  st public.staff%rowtype; cfg public.school_settings%rowtype;
  d integer; v_now timestamptz := now(); v_local timestamp; v_date date;
  v_start timestamp; v_status text; a public.staff_attendance%rowtype; v_action text; v_shift time;
begin
  select * into st from public.staff where user_id = auth.uid() and status = 'active';
  if not found then raise exception 'No active staff record is linked to this login'; end if;
  select * into cfg from public.school_settings limit 1;
  if cfg.geo_lat is null or cfg.geo_lng is null then raise exception 'School location is not set yet. Ask the owner to set it in Staff > Settings'; end if;
  if p_lat is null or p_lng is null then raise exception 'Location not received'; end if;
  d := round(6371000 * 2 * asin(sqrt(
        power(sin(radians(p_lat - cfg.geo_lat) / 2), 2) +
        cos(radians(cfg.geo_lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - cfg.geo_lng) / 2), 2))));
  if p_accuracy is not null and p_accuracy > 150 then
    insert into public.staff_punch_log(staff_id, lat, lng, accuracy_m, distance_m, inside, result) values (st.id, p_lat, p_lng, p_accuracy, d, false, 'weak_gps');
    raise exception 'GPS is not accurate enough (% m). Move near a window or open sky, switch on high accuracy location, and try again', round(p_accuracy)::int;
  end if;
  if d > cfg.geo_radius_m then
    insert into public.staff_punch_log(staff_id, lat, lng, accuracy_m, distance_m, inside, result) values (st.id, p_lat, p_lng, p_accuracy, d, false, 'outside');
    raise exception 'You are % m from school. Punch works only within % m', d, cfg.geo_radius_m;
  end if;
  v_local := v_now at time zone 'Asia/Kolkata';
  v_date := v_local::date;
  v_shift := coalesce(st.shift_start, cfg.shift_start);
  select * into a from public.staff_attendance where staff_id = st.id and work_date = v_date;
  if not found then
    v_start := v_date + v_shift;
    v_status := case
      when v_local <= v_start + make_interval(mins => cfg.grace_minutes) then 'present'
      when v_local <= v_start + make_interval(mins => cfg.halfday_after_minutes) then 'late'
      else 'half_day' end;
    insert into public.staff_attendance(staff_id, work_date, status, check_in, in_distance_m, source)
      values (st.id, v_date, v_status, v_now, d, 'geofence');
    v_action := 'check_in';
  else
    if a.status in ('paid_leave','unpaid_leave','absent') and a.check_in is null then
      raise exception 'Today is marked as % by the owner', replace(a.status, '_', ' ');
    end if;
    if a.check_in is null then
      update public.staff_attendance set check_in = v_now, in_distance_m = d where id = a.id; v_action := 'check_in';
    else
      update public.staff_attendance set check_out = v_now, out_distance_m = d where id = a.id; v_action := 'check_out';
    end if;
    v_status := a.status;
  end if;
  insert into public.staff_punch_log(staff_id, lat, lng, accuracy_m, distance_m, inside, result) values (st.id, p_lat, p_lng, p_accuracy, d, true, v_action);
  return jsonb_build_object('action', v_action, 'status', v_status, 'distance_m', d, 'at', v_now);
end $$;
