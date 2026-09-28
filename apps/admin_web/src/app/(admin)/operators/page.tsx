import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

export default async function OperatorsPage() {
  const supabase = await createClient();
  const { data: operators } = await supabase
    .from("operators")
    .select("id, name, business_type, status, contact_email, contact_phone, created_at")
    .order("created_at", { ascending: false });

  return (
    <div>
      <PageTitle title="Operators" subtitle="Bus operators and cargo transporters on the platform" />
      <Table>
        <thead>
          <tr>
            <Th>Name</Th>
            <Th>Type</Th>
            <Th>Contact</Th>
            <Th>Status</Th>
            <Th>Applied</Th>
          </tr>
        </thead>
        <tbody>
          {operators?.map((op) => (
            <tr key={op.id}>
              <Td>
                <Link href={`/operators/${op.id}`} className="font-medium text-indigo-400 hover:underline">
                  {op.name}
                </Link>
              </Td>
              <Td className="capitalize">{op.business_type}</Td>
              <Td>
                <div>{op.contact_email}</div>
                <div className="text-slate-500">{op.contact_phone}</div>
              </Td>
              <Td>
                <Badge status={op.status} />
              </Td>
              <Td>{new Date(op.created_at).toLocaleDateString()}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!operators?.length && <EmptyState message="No operators yet." />}
    </div>
  );
}
