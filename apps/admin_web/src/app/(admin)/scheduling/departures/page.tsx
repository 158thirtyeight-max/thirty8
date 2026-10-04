import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { DecisionButtons, RunNowButton } from "./cancellation-actions";

type Params = { from?: string; to?: string; status?: string };

type TripRow = {
  id: string;
  travel_date: string;
  departure_at: string;
  status: string;
  available_seats: number;
  generated_by: string;
  cancellation_request_status: string;
  cancellation_reason: string | null;
  bus_services: { service_name: string; bus_routes: { source: { name: string } | null; destination: { name: string } | null } | null } | null;
  operators: { name: string } | null;
};

type RunRow = {
  id: string;
  trigger_source: string;
  status: string;
  services_processed: number;
  trips_created: number;
  error_count: number;
  started_at: string;
};

type ErrorRow = {
  id: string;
  error_code: string;
  message: string;
  created_at: string;
  bus_services: { service_name: string } | null;
};

const TRIP_SELECT =
  "id, travel_date, departure_at, status, available_seats, generated_by, cancellation_request_status, cancellation_reason, " +
  "bus_services(service_name, bus_routes:route_id(source:source_city_id(name), destination:destination_city_id(name))), operators(name)";

function routeLabel(t: TripRow) {
  const r = t.bus_services?.bus_routes;
  return r ? `${r.source?.name ?? "?"} → ${r.destination?.name ?? "?"}` : (t.bus_services?.service_name ?? "—");
}

export default async function DeparturesPage({ searchParams }: { searchParams: Promise<Params> }) {
  const { from, to, status } = await searchParams;
  const supabase = await createClient();

  let query = supabase.from("bus_trips").select(TRIP_SELECT).order("departure_at", { ascending: true }).limit(200);
  query = query.gte("travel_date", from || new Date().toISOString().slice(0, 10));
  if (to) query = query.lte("travel_date", to);
  if (status) query = query.eq("status", status);

  const [{ data: trips }, { data: requests }, { data: runs }, { data: errors }] = await Promise.all([
    query.returns<TripRow[]>(),
    supabase
      .from("bus_trips")
      .select(TRIP_SELECT)
      .eq("cancellation_request_status", "requested")
      .order("cancellation_requested_at", { ascending: true })
      .returns<TripRow[]>(),
    supabase.from("schedule_generation_runs").select("*").order("started_at", { ascending: false }).limit(8).returns<RunRow[]>(),
    supabase
      .from("schedule_generation_errors")
      .select("id, error_code, message, created_at, bus_services(service_name)")
      .order("created_at", { ascending: false })
      .limit(20)
      .returns<ErrorRow[]>(),
  ]);

  return (
    <div className="space-y-10">
      <PageTitle title="Departures & Generation" subtitle="Departure instances generated from operators' recurring schedules, cancellation requests and generator health" />

      <section>
        <SectionHeader title={`Cancellation requests (${requests?.length ?? 0})`} />
        <Table>
          <thead>
            <tr>
              <Th>Departure</Th>
              <Th>Operator</Th>
              <Th>Reason</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody>
            {requests?.map((t) => (
              <tr key={t.id}>
                <Td>
                  {routeLabel(t)}
                  <div className="text-xs text-text-tertiary">{new Date(t.departure_at).toLocaleString()}</div>
                </Td>
                <Td>{t.operators?.name}</Td>
                <Td>{t.cancellation_reason}</Td>
                <Td>
                  <DecisionButtons tripId={t.id} />
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!requests?.length && <EmptyState message="No pending cancellation requests." />}
      </section>

      <section>
        <SectionHeader title="Generation runs" action={<RunNowButton />} />
        <Table>
          <thead>
            <tr>
              <Th>Started</Th>
              <Th>Source</Th>
              <Th>Status</Th>
              <Th>Services</Th>
              <Th>Departures created</Th>
              <Th>Errors</Th>
            </tr>
          </thead>
          <tbody>
            {runs?.map((r) => (
              <tr key={r.id}>
                <Td>{new Date(r.started_at).toLocaleString()}</Td>
                <Td>{r.trigger_source}</Td>
                <Td>
                  <Badge status={r.status === "completed" ? "active" : r.status === "running" ? "pending" : "failed"} />
                </Td>
                <Td>{r.services_processed}</Td>
                <Td>{r.trips_created}</Td>
                <Td>{r.error_count}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!runs?.length && <EmptyState message="The generator has not run yet." />}
      </section>

      <section>
        <SectionHeader title="Generation failures" />
        <Table>
          <thead>
            <tr>
              <Th>When</Th>
              <Th>Schedule</Th>
              <Th>Code</Th>
              <Th>Message</Th>
            </tr>
          </thead>
          <tbody>
            {errors?.map((e) => (
              <tr key={e.id}>
                <Td>{new Date(e.created_at).toLocaleString()}</Td>
                <Td>{e.bus_services?.service_name ?? "—"}</Td>
                <Td className="font-mono text-xs">{e.error_code}</Td>
                <Td>{e.message}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!errors?.length && <EmptyState message="No generation failures recorded." />}
      </section>

      <section>
        <SectionHeader title="Generated departures" />
        <form className="mb-3 flex flex-wrap items-end gap-3 text-sm">
          <label className="flex flex-col gap-1">
            From
            <input type="date" name="from" defaultValue={from} className="rounded-md border border-border bg-background px-2 py-1.5" />
          </label>
          <label className="flex flex-col gap-1">
            To
            <input type="date" name="to" defaultValue={to} className="rounded-md border border-border bg-background px-2 py-1.5" />
          </label>
          <label className="flex flex-col gap-1">
            Status
            <select name="status" defaultValue={status ?? ""} className="rounded-md border border-border bg-background px-2 py-1.5">
              <option value="">All</option>
              {["scheduled", "boarding", "departed", "arrived", "cancelled"].map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </label>
          <button className="rounded-md border border-border px-3 py-1.5 font-medium hover:border-primary hover:text-primary">Filter</button>
        </form>
        <Table>
          <thead>
            <tr>
              <Th>Departure</Th>
              <Th>Route</Th>
              <Th>Operator</Th>
              <Th>Seats left</Th>
              <Th>Source</Th>
              <Th>Status</Th>
            </tr>
          </thead>
          <tbody>
            {trips?.map((t) => (
              <tr key={t.id}>
                <Td>{new Date(t.departure_at).toLocaleString()}</Td>
                <Td>{routeLabel(t)}</Td>
                <Td>{t.operators?.name}</Td>
                <Td>{t.available_seats}</Td>
                <Td className="capitalize">{t.generated_by}</Td>
                <Td>
                  <Badge status={t.cancellation_request_status === "requested" ? "pending" : t.status} />
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!trips?.length && <EmptyState message="No departures match." />}
      </section>
    </div>
  );
}
