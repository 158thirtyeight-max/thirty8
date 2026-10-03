import { fmtDateTime } from "@/lib/format-date";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

type BookingRow = {
  id: string;
  booking_reference: string;
  status: string;
  total_fare_cents: number;
  contact_email: string | null;
  created_at: string;
  profiles: { full_name: string | null; email: string | null } | null;
};

export default async function BookingsPage() {
  const supabase = await createClient();
  const { data: bookings } = await supabase
    .from("bookings")
    .select("id, booking_reference, status, total_fare_cents, contact_email, created_at, profiles(full_name, email)")
    .order("created_at", { ascending: false })
    .limit(200)
    .returns<BookingRow[]>();

  return (
    <div>
      <PageTitle title="Bookings" subtitle="Bus bookings across all operators (most recent 200)" />
      <Table>
        <thead>
          <tr>
            <Th>Reference</Th>
            <Th>Customer</Th>
            <Th>Fare</Th>
            <Th>Status</Th>
            <Th>Created</Th>
          </tr>
        </thead>
        <tbody>
          {bookings?.map((b) => (
            <tr key={b.id}>
              <Td className="font-mono">{b.booking_reference}</Td>
              <Td>{b.profiles?.full_name ?? b.profiles?.email ?? b.contact_email}</Td>
              <Td>₹{(b.total_fare_cents / 100).toLocaleString("en-IN")}</Td>
              <Td>
                <Badge status={b.status} />
              </Td>
              <Td>{fmtDateTime(b.created_at)}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!bookings?.length && <EmptyState message="No bookings yet." />}
    </div>
  );
}
