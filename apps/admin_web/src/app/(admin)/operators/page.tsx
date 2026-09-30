import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

const FILTERS: { key: string; label: string }[] = [
  { key: "all", label: "All" },
  { key: "submitted", label: "Submitted" },
  { key: "under_review", label: "Under review" },
  { key: "changes_requested", label: "Changes requested" },
  { key: "approved", label: "Approved" },
  { key: "rejected", label: "Rejected" },
  { key: "draft", label: "Draft" },
];

export default async function OperatorsPage({ searchParams }: { searchParams: Promise<{ app?: string }> }) {
  const { app } = await searchParams;
  const filter = FILTERS.some((f) => f.key === app) ? (app as string) : "all";

  const supabase = await createClient();
  let query = supabase
    .from("operators")
    .select("id, name, business_type, status, application_status, contact_email, contact_phone, created_at, submitted_at")
    .order("submitted_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false });
  if (filter !== "all") query = query.eq("application_status", filter);
  const { data: operators } = await query;

  return (
    <div>
      <PageTitle title="Operators" subtitle="Operator applications and approved operators" />

      <div className="mb-4 flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <Link
            key={f.key}
            href={f.key === "all" ? "/operators" : `/operators?app=${f.key}`}
            className={`rounded-pill px-3 py-1 text-sm transition ${
              filter === f.key ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"
            }`}
          >
            {f.label}
          </Link>
        ))}
      </div>

      <Table>
        <thead>
          <tr>
            <Th>Name</Th>
            <Th>Type</Th>
            <Th>Contact</Th>
            <Th>Application</Th>
            <Th>Account</Th>
            <Th>Submitted</Th>
          </tr>
        </thead>
        <tbody>
          {operators?.map((op) => (
            <tr key={op.id}>
              <Td>
                <Link href={`/operators/${op.id}`} className="font-medium text-primary hover:underline">
                  {op.name}
                </Link>
              </Td>
              <Td className="capitalize">{op.business_type}</Td>
              <Td>
                <div>{op.contact_email}</div>
                <div className="text-text-tertiary">{op.contact_phone}</div>
              </Td>
              <Td>
                <Badge status={op.application_status ?? op.status} />
              </Td>
              <Td>
                <Badge status={op.status} />
              </Td>
              <Td>{op.submitted_at ? new Date(op.submitted_at).toLocaleDateString() : "—"}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!operators?.length && <EmptyState message="No operators match this filter." />}
    </div>
  );
}
