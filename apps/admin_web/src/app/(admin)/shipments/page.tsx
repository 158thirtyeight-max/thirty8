import { fmtDateTime } from "@/lib/format-date";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

type ShipmentRow = {
  id: string;
  shipment_reference: string;
  status: string;
  total_fare_cents: number;
  weight_kg: number;
  created_at: string;
  operators: { name: string } | null;
  profiles: { full_name: string | null; email: string | null } | null;
};

export default async function ShipmentsPage() {
  const supabase = await createClient();
  const { data: shipments } = await supabase
    .from("cargo_shipments")
    .select("id, shipment_reference, status, total_fare_cents, weight_kg, created_at, operators(name), profiles!cargo_shipments_sender_user_id_fkey(full_name, email)")
    .order("created_at", { ascending: false })
    .limit(200)
    .returns<ShipmentRow[]>();

  return (
    <div>
      <PageTitle title="Shipments" subtitle="Cargo shipments across all operators (most recent 200)" />
      <Table>
        <thead>
          <tr>
            <Th>Reference</Th>
            <Th>Sender</Th>
            <Th>Operator</Th>
            <Th>Weight</Th>
            <Th>Fare</Th>
            <Th>Status</Th>
            <Th>Created</Th>
          </tr>
        </thead>
        <tbody>
          {shipments?.map((s) => (
            <tr key={s.id}>
              <Td className="font-mono">{s.shipment_reference}</Td>
              <Td>{s.profiles?.full_name ?? s.profiles?.email ?? "—"}</Td>
              <Td>{s.operators?.name ?? "—"}</Td>
              <Td>{s.weight_kg} kg</Td>
              <Td>₹{(s.total_fare_cents / 100).toLocaleString("en-IN")}</Td>
              <Td>
                <Badge status={s.status} />
              </Td>
              <Td>{fmtDateTime(s.created_at)}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!shipments?.length && <EmptyState message="No shipments yet." />}
    </div>
  );
}
