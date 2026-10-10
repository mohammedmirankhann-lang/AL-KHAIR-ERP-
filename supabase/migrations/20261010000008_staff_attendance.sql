-- Staff directory + geofence attendance.

alter table school_settings
  add column if not exists geo_lat numeric(9,6),
  add column if not exists geo_lng numeric(9,6),
  add column if not exists geo_radius_m integer not null default 150 check (geo_radius_m between 20 and 2000),
  add column if not exists shift_start time not null default '08:00',
  add column if not exists shift_end time not null default '14:00',
  add column if not exists grace_minutes integer not null default 15 check (grace_minutes >= 0),
  add column if not exists halfday_after_minutes integer not null default 120 check (halfday_after_minutes >= 0),
  add column if not exists weekly_off integer[] not null default '{0}',   -- 0 = Sunday
  add column if not exists paid_leaves_per_month numeric(4,1);            -- null until the owner decides

create table if not exists staff (
  id uuid primary key default gen_random_uuid(),
  staff_code text unique,
  full_name text not null,
  designation text,
  subjects text,
  classes_taught text,
  phone text,
  email text,
  dob date,
  gender text check (gender in ('male','female','other')),
  joined_on date,
  qualification text,
  address text,
  aadhaar_last4 text check (aadhaar_last4 ~ '^[0-9]{4}$'),
  monthly_salary numeric(10,0) check (monthly_salary >= 0),
  status text not null default 'active' check (status in ('active','left')),
  user_id uuid unique references auth.users(id) on delete set null,
  login_id text,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists staff_attendance (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id) on delete cascade,
  work_date date not null,
  status text not null check (status in ('present','late','half_day','paid_leave','unpaid_leave','absent')),
  check_in timestamptz,
  check_out timestamptz,
  in_distance_m integer,
  out_distance_m integer,
  source text not null default 'geofence' check (source in ('geofence','manual')),
  note text,
  marked_by uuid,
  created_at timestamptz not null default now(),
  unique (staff_id, work_date)
);

create table if not exists staff_punch_log (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id) on delete cascade,
  at timestamptz not null default now(),
  lat double precision, lng double precision, accuracy_m double precision,
  distance_m integer, inside boolean not null,
  result text not null
);

create table if not exists school_holidays (
  holiday_on date primary key,
  name text not null
);

alter table staff enable row level security;
alter table staff_attendance enable row level security;
alter table staff_punch_log enable row level security;
alter table school_holidays enable row level security;

create policy owner_all on staff for all using (is_owner()) with check (is_owner());
create policy self_read on staff for select using (user_id = auth.uid());
create policy owner_all on staff_attendance for all using (is_owner()) with check (is_owner());
create policy self_read on staff_attendance for select using (staff_id in (select id from staff where user_id = auth.uid()));
create policy owner_all on staff_punch_log for all using (is_owner()) with check (is_owner());
create policy owner_all on school_holidays for all using (is_owner()) with check (is_owner());
create policy staff_read on school_holidays for select using (auth.uid() is not null);

-- Teachers punch in and out only through this function. Distance is computed on the server.
create or replace function public.staff_punch(p_lat double precision, p_lng double precision, p_accuracy double precision default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  st public.staff%rowtype; cfg public.school_settings%rowtype;
  d integer; v_now timestamptz := now(); v_local timestamp; v_date date;
  v_start timestamp; v_status text; a public.staff_attendance%rowtype; v_action text;
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
  select * into a from public.staff_attendance where staff_id = st.id and work_date = v_date;

  if not found then
    v_start := v_date + cfg.shift_start;
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
revoke all on function public.staff_punch(double precision, double precision, double precision) from public, anon;
grant execute on function public.staff_punch(double precision, double precision, double precision) to authenticated;
