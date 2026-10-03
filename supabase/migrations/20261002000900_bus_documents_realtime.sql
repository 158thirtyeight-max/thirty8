-- Operators see document rejections live: stream bus_documents changes via
-- Supabase Realtime (RLS still limits each operator to their own buses).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bus_documents'
  ) then
    alter publication supabase_realtime add table public.bus_documents;
  end if;
end $$;
