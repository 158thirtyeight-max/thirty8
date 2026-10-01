import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

/* eslint-disable @typescript-eslint/no-explicit-any */

function duration(min: number | null) {
  return min ? `${Math.floor(min / 60)}h ${min % 60}m` : "—";
}

export default async function RoutesPage() {
  const supabase = await createClient();
  const { data: routes } = await supabase
    .from("route_templates")
    .select("*, source:locations!route_templates_source_city_id_fkey(name), destination:locations!route_templates_destination_city_id_fkey(name), stops:route_template_stops(count)")
    .order("name");

  return (
    <div>
      <PageTitle title="Routes" subtitle="The route catalog shared by the admin panel, operator app and customer app. Operators start from these routes; you can also assign one directly to a bus." />
      <div className="mb-4">
        <Link href="/routes/new" className="inline-block rounded-md bg-primary px-4 py-2 text-sm font-medium text-white transition hover:bg-primary-dark">
          Add route
        </Link>
      </div>
      <Table>
        <thead>
          <tr>
            <Th>Name</Th>
            <Th>From → To</Th>
            <Th>Stops</Th>
            <Th>Distance</Th>
            <Th>Journey</Th>
            <Th>Status</Th>
            <Th />
          </tr>
        </thead>
        <tbody>
          {(routes ?? []).map((r: any) => (
            <tr key={r.id}>
              <Td>{r.name}</Td>
              <Td>
                {r.source?.name} → {r.destination?.name}
              </Td>
              <Td>{r.stops?.[0]?.count ?? 0}</Td>
              <Td>{r.distance_km ? `${r.distance_km} km` : "—"}</Td>
              <Td>{duration(r.est_duration_min)}</Td>
              <Td>
                <Badge status={r.is_active ? "active" : "inactive"} />
              </Td>
              <Td>
                <Link href={`/routes/${r.id}`} className="text-primary hover:underline">
                  Edit
                </Link>
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!routes?.length && <EmptyState message="No routes yet. Add the first one." />}
    </div>
  );
}
