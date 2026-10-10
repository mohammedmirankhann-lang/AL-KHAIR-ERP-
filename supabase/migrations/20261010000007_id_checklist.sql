-- ID checklist: PEN, APAAR, Aadhaar, Samagra shown as submitted / missing.
-- The "Aadhaar card (student)" document row is replaced by the Aadhaar ID flag.
update document_types set is_active=false where code='student_aadhaar';

create or replace view v_student_id_status with (security_invoker=true) as
select e.id as enrollment_id, s.id as student_id, s.admission_no, s.full_name, s.father_name,
       s.guardian_mobile, c.name as class_name, c.sort_order,
       (nullif(trim(s.pen),'') is not null)         as has_pen,
       (nullif(trim(s.apaar_id),'') is not null)    as has_apaar,
       (nullif(trim(s.aadhaar_last4),'') is not null) as has_aadhaar,
       (nullif(trim(s.samagra_id),'') is not null)  as has_samagra
from enrollments e
join academic_years y on y.id=e.academic_year_id and y.is_current
join students s on s.id=e.student_id and s.status='active'
join classes c on c.id=e.class_id;
grant select on v_student_id_status to authenticated;

-- Nursery children have no PEN or APAAR yet, so those are not counted as missing for Nursery.
create or replace view v_student_id_status with (security_invoker=true) as
select e.id as enrollment_id, s.id as student_id, s.admission_no, s.full_name, s.father_name,
       s.guardian_mobile, c.name as class_name, c.sort_order,
       (nullif(trim(s.pen),'') is not null) as has_pen,
       (nullif(trim(s.apaar_id),'') is not null) as has_apaar,
       (nullif(trim(s.aadhaar_last4),'') is not null) as has_aadhaar,
       (nullif(trim(s.samagra_id),'') is not null) as has_samagra,
       (c.name <> 'Nursery') as req_pen, (c.name <> 'Nursery') as req_apaar,
       true as req_aadhaar, true as req_samagra
from enrollments e
join academic_years y on y.id=e.academic_year_id and y.is_current
join students s on s.id=e.student_id and s.status='active'
join classes c on c.id=e.class_id;
