-- Student document scans: private bucket, upload fields, a document counts as received only with a file attached.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values ('student-docs','student-docs',false,6291456,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict (id) do nothing;
create policy student_docs_read on storage.objects for select to authenticated using (bucket_id = 'student-docs' and public.can_manage_accounts());
create policy student_docs_ins on storage.objects for insert to authenticated with check (bucket_id = 'student-docs' and public.can_manage_accounts());
create policy student_docs_upd on storage.objects for update to authenticated using (bucket_id = 'student-docs' and public.can_manage_accounts()) with check (bucket_id = 'student-docs' and public.can_manage_accounts());
alter table public.student_documents add column if not exists file_name text, add column if not exists file_type text, add column if not exists uploaded_at timestamptz, add column if not exists uploaded_by uuid, add column if not exists checked boolean not null default false, add column if not exists checked_by uuid, add column if not exists checked_at timestamptz;
alter table public.student_documents add constraint received_needs_file check (status <> 'received' or storage_path is not null);
create policy office_del on public.student_documents for delete using (public.can_manage_accounts());
create or replace view public.v_student_missing_documents as
 SELECT s.id AS student_id, s.admission_no, s.full_name, c.name AS class_name, dt.id AS document_type_id, dt.name AS document_name
   FROM enrollments e
   JOIN academic_years y ON y.id = e.academic_year_id AND y.is_current
   JOIN students s ON s.id = e.student_id AND s.status = 'active'
   JOIN classes c ON c.id = e.class_id
   JOIN document_types dt ON dt.is_active AND c.sort_order >= dt.required_from_order
  WHERE NOT EXISTS (SELECT 1 FROM student_documents d WHERE d.student_id = s.id AND d.document_type_id = dt.id AND ((d.status = 'received' AND d.storage_path IS NOT NULL) OR d.status = 'not_applicable'));
