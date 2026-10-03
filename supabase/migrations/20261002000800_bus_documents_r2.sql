-- =========================================================================
-- Bus documents move to Cloudflare R2. New files are stored in a private R2
-- bucket under  bus-documents/<operator_id>/<bus_id>/<doc_type>_<uuid>.<ext>
-- and rows carry bucket = 'r2'. Older rows keep their Supabase Storage bucket.
-- Files are served only through short-lived presigned URLs (r2-document-url).
-- =========================================================================

alter table public.bus_documents drop constraint bus_documents_bucket_check;
alter table public.bus_documents
  add constraint bus_documents_bucket_check check (bucket in ('bus-documents', 'insurance-documents', 'r2'));

-- Replacing the file keeps the bucket the uploader declared (r2 or the legacy
-- bucket); the insurance-documents bucket can no longer be chosen.
create or replace function private.protect_bus_document_review()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') or public.am_i_platform_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.status := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.rejection_reason := null;
    new.version := 1;
    if new.bucket = 'insurance-documents' then
      new.bucket := 'bus-documents';
    end if;
    return new;
  end if;

  if new.bus_id is distinct from old.bus_id then
    raise exception 'A document cannot be moved to another bus';
  end if;

  if new.file_path is distinct from old.file_path
     or new.doc_number is distinct from old.doc_number
     or new.issue_date is distinct from old.issue_date
     or new.expiry_date is distinct from old.expiry_date then
    new.status := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.rejection_reason := null;
    new.version := old.version + 1;
    if new.file_path is distinct from old.file_path and new.bucket = 'insurance-documents' then
      new.bucket := 'bus-documents';
    end if;
  elsif new.status is distinct from old.status
    or new.reviewed_by is distinct from old.reviewed_by
    or new.reviewed_at is distinct from old.reviewed_at
    or new.rejection_reason is distinct from old.rejection_reason
    or new.version is distinct from old.version then
    raise exception 'Only platform admins can change document verification';
  end if;
  return new;
end;
$$;

-- Ownership check covers both layouts (the R2 key has a leading 'bus-documents/').
create or replace function private.validate_bus_document_file()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_operator uuid;
  v_off int;
begin
  if not exists (
    select 1 from public.document_requirements dr where dr.scope = 'bus' and dr.doc_type = new.doc_type
  ) then
    raise exception 'Unknown vehicle document type %', new.doc_type;
  end if;

  if new.bucket in ('bus-documents', 'r2')
     and (tg_op = 'INSERT' or new.file_path is distinct from old.file_path or new.bucket is distinct from old.bucket) then
    select operator_id into v_operator from public.buses where id = new.bus_id;
    v_off := case when new.bucket = 'r2' then 1 else 0 end;
    if new.bucket = 'r2' and split_part(new.file_path, '/', 1) is distinct from 'bus-documents' then
      raise exception 'The document file does not belong to this bus';
    end if;
    if split_part(new.file_path, '/', 1 + v_off) is distinct from v_operator::text
       or split_part(new.file_path, '/', 2 + v_off) is distinct from new.bus_id::text
       or split_part(new.file_path, '/', 3 + v_off) not like new.doc_type || '\_%' then
      raise exception 'The document file does not belong to this bus';
    end if;
  end if;
  return new;
end;
$$;
