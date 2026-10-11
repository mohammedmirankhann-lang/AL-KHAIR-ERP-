-- Report card: subject groups/components, Deeniyat card subjects, traits/remark/height/weight per evaluation.
alter table public.subjects add column if not exists report_group text;
alter table public.subjects add column if not exists component text;
alter table public.subjects add column if not exists card text not null default 'main';
alter table public.subjects drop constraint if exists subjects_card_check;
alter table public.subjects add constraint subjects_card_check check (card in ('main','deeniyat','retired'));

insert into public.subjects(name, sort_order, report_group, component, card) values
 ('Arabic - Written', 20, 'ARABIC', 'Arabic Written', 'deeniyat'),
 ('Arabic - Nazra Quran with Tajweed', 21, 'ARABIC', 'Nazra Quran with Tajweed', 'deeniyat'),
 ('Arabic - Haroof Sifat with TPI', 22, 'ARABIC', 'Haroof Sifat with TPI', 'deeniyat'),
 ('Arabic - Project', 23, 'ARABIC', 'Project', 'deeniyat'),
 ('Islamiyat - Aqeeda & Akhlaq', 30, 'ISLAMIYAT', 'Aqeeda & Akhlaq', 'deeniyat'),
 ('Islamiyat - Fiqh & Seerat', 31, 'ISLAMIYAT', 'Fiqh & Seerat', 'deeniyat'),
 ('Islamiyat - Hifz-e-Surah', 32, 'ISLAMIYAT', 'Hifz-e-Surah', 'deeniyat'),
 ('Islamiyat - Hifz-e-Hadeeth', 33, 'ISLAMIYAT', 'Hifz-e-Hadeeth', 'deeniyat'),
 ('Islamiyat - Hifz-e-Dua', 34, 'ISLAMIYAT', 'Hifz-e-Dua', 'deeniyat')
on conflict (name) do nothing;

-- carry the old single Arabic / Islamiyat subjects (no marks yet) over to the components
insert into public.class_subjects(class_id, subject_id)
select cs.class_id, n.id from public.class_subjects cs join public.subjects o on o.id = cs.subject_id
join public.subjects n on n.card = 'deeniyat' and n.report_group = upper(o.name) where o.name in ('Arabic','Islamiyat')
on conflict do nothing;
insert into public.teacher_assignments(staff_id, class_id, subject_id, is_class_teacher, academic_year_id)
select a.staff_id, a.class_id, n.id, false, a.academic_year_id from public.teacher_assignments a join public.subjects o on o.id = a.subject_id
join public.subjects n on n.card = 'deeniyat' and n.report_group = upper(o.name) where o.name in ('Arabic','Islamiyat')
on conflict do nothing;
-- old single Arabic / Islamiyat subjects are retired (hidden from marks entry and report cards)
update public.subjects set card = 'retired' where name in ('Arabic','Islamiyat');

create table if not exists public.report_extras (
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  eval smallint not null check (eval in (1,2)),
  traits jsonb not null default '{}'::jsonb,
  remark text,
  height_cm numeric(5,1),
  weight_kg numeric(5,1),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (enrollment_id, eval)
);
alter table public.report_extras enable row level security;
create policy owner_all on public.report_extras for all using (is_owner()) with check (is_owner());

create or replace function public.teacher_get_extras(p_class uuid, p_eval int) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_class(p_class, null, true);
  return coalesce((select jsonb_agg(jsonb_build_object('enrollment_id', x.enrollment_id, 'traits', x.traits, 'remark', x.remark, 'height_cm', x.height_cm, 'weight_kg', x.weight_kg))
    from public.report_extras x join public.enrollments e on e.id = x.enrollment_id where e.class_id = p_class and x.eval = p_eval), '[]'::jsonb);
end $$;

create or replace function public.teacher_save_extras(p_class uuid, p_eval int, p_rows jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare r jsonb; n int := 0;
begin
  perform private.require_class(p_class, null, true);
  if p_eval not in (1,2) then raise exception 'Evaluation must be 1 or 2'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if not exists (select 1 from public.enrollments e where e.id = (r ->> 'enrollment_id')::uuid and e.class_id = p_class) then
      raise exception 'A student in the list is not in this class';
    end if;
    insert into public.report_extras(enrollment_id, eval, traits, remark, height_cm, weight_kg, updated_by, updated_at)
    values ((r ->> 'enrollment_id')::uuid, p_eval, coalesce(r -> 'traits', '{}'::jsonb), nullif(r ->> 'remark',''), nullif(r ->> 'height_cm','')::numeric, nullif(r ->> 'weight_kg','')::numeric, auth.uid(), now())
    on conflict (enrollment_id, eval) do update set traits = excluded.traits, remark = excluded.remark, height_cm = excluded.height_cm, weight_kg = excluded.weight_kg, updated_by = excluded.updated_by, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.teacher_get_extras(uuid,int), public.teacher_save_extras(uuid,int,jsonb) from public, anon;
grant execute on function public.teacher_get_extras(uuid,int), public.teacher_save_extras(uuid,int,jsonb) to authenticated;
