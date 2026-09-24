/// Supabase project configuration. The anon/publishable key is designed to
/// be embedded in client apps — it's public by intent, and the RLS policies
/// in supabase/migrations are what actually control access, not this key.
class Env {
  static const supabaseUrl = 'https://xdrthrdwdfzhzhqkhnnf.supabase.co';
  static const supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhkcnRocmR3ZGZ6aHpocWtobm5mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAxMTE0NDEsImV4cCI6MjEwNTY4NzQ0MX0.kvQh1VCA5vxc0ghKDfKVDpcLkGTTnioQ5gpCav119zo';
}
