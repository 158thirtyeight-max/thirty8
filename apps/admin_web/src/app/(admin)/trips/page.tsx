import { fmtDateTime } from "@/lib/format-date";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

/* eslint-disable @typescript-eslint/no-explicit-any */

const FILTERS = [
  { key: "active", label: "In progress", statuses: ["boarding", "departed"] },
  { key: "upcoming", label: "Upcoming", statuses: ["scheduled"] },
  { key: "done", label: "Completed", statuses: ["arrived"] },
  { key: "cancelled", label: "Cancelled", statuses: ["cancelled"] },
];

export default async function TripsPage({ searchParams }: { searchParams: Promise<{ f?: string }> }) {
  const { f } = await searchParams;
  const filter = FILTERS.find((x) => x.key === f) ?? FILTERS[0];
  const supabase = await createClient();

  const { data: trips } = await supabase
    .from("bus_trips")
    .select(
      "id, status, departure_at, available_seats, buses(registration_number), operators(name), route:bus_routes(source:locations!bus_routes_source_city_id_fkey(name), destination:locations!bus_routes_destination_city_id_fkey(name))",
    )
    .in("status", filter.statuses)
    .order("departure_at", { ascending: filter.key !== "done" && filter.key !== "cancelled" })
    .limit(100);

  return (
    <div>
      <PageTitle title="Trips" subtitle="Open a trip to see its live seat map, bookings and tracking" />
      <div className="mb-4 flex flex-wrap gap-2">
        {FILTERS.map((x) => (
          <Link
            key={x.key}
            href={`/trips?f=${x.key}`}
            className={`rounded-pill px-3 py-1 text-sm transition ${
              filter.key === x.key ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"
            }`}
          >
            {x.label}
          </Link>
        ))}
      </div>
      <Table>
        <thead>
          <tr><Th>Route</Th><Th>Bus</Th><Th>Operator</Th><Th>Departure</Th><Th>Seats left</Th><Th>Status</Th></tr>
        </thead>
        <tbody>
          {(trips as any[] | null)?.map((t) => (
            <tr key={t.id}>
              <Td>
                <Link href={`/trips/${t.id}`} className="text-primary hover:underline">
                  {t.route?.source?.name ?? "—"} → {t.route?.destination?.name ?? "—"}
                </Link>
              </Td>
              <Td>{t.buses?.registration_number}</Td>
              <Td>{t.operators?.name}</Td>
              <Td>{fmtDateTime(t.departure_at)}</Td>
              <Td>{t.available_seats}</Td>
              <Td><Badge status={t.status} /></Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!trips?.length && <EmptyState message="No trips in this list." />}
    </div>
  );
}
