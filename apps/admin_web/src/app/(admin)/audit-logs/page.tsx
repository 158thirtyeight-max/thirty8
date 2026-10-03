import { fmtDateTime } from "@/lib/format-date";
import { createClient } from "@/lib/supabase/server";
import { EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

type AuditLogRow = {
  id: string;
  action: string;
  entity_type: string;
  entity_id: string;
  created_at: string;
  profiles: { full_name: string | null; email: string | null } | null;
};

export default async function AuditLogsPage() {
  const supabase = await createClient();
  const { data: logs } = await supabase
    .from("audit_logs")
    .select("id, action, entity_type, entity_id, created_at, profiles:actor_profile_id(full_name, email)")
    .order("created_at", { ascending: false })
    .limit(200)
    .returns<AuditLogRow[]>();

  return (
    <div>
      <PageTitle title="Audit logs" subtitle="Sensitive admin actions on the platform" />
      <Table>
        <thead>
          <tr>
            <Th>When</Th>
            <Th>Actor</Th>
            <Th>Action</Th>
            <Th>Entity</Th>
          </tr>
        </thead>
        <tbody>
          {logs?.map((l) => (
            <tr key={l.id}>
              <Td>{fmtDateTime(l.created_at)}</Td>
              <Td>{l.profiles?.full_name ?? l.profiles?.email ?? "system"}</Td>
              <Td>{l.action}</Td>
              <Td className="font-mono text-xs">
                {l.entity_type} · {l.entity_id}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!logs?.length && <EmptyState message="No audit events recorded yet." />}
    </div>
  );
}
