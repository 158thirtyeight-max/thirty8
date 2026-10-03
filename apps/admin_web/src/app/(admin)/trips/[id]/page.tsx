import { fmtDateTime } from "@/lib/format-date";
import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Badge, PageTitle, SectionHeader, StatCard } from "@/components/ui";
import { SeatStatusMap } from "@/components/seat-status-map";
import { LiveRefresh } from "./live-refresh";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function TripPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: trip }, { data: map, error: mapError }, { data: tracking }, { data: stats }] = await Promise.all([
    supabase
      .from("bus_trips")
      .select(
        "id, status, departure_at, arrival_at, buses(registration_number), operators(name), route:bus_routes(source:locations!bus_routes_source_city_id_fkey(name), destination:locations!bus_routes_destination_city_id_fkey(name))",
      )
      .eq("id", id)
      .maybeSingle(),
    supabase.rpc("get_operator_trip_seat_map", { p_trip_id: id }),
    supabase.rpc("get_trip_tracking", { p_trip_id: id }),
    supabase.rpc("get_trip_booking_stats", { p_trip_id: id }),
  ]);
  if (!trip || mapError) notFound();

  const t: any = trip;
  const m: any = map;
  const tr: any = tracking;
  const s: any = stats;

  return (
    <div>
      <p className="mb-2 text-sm">
        <Link href="/trips" className="text-primary hover:underline">← All trips</Link>
      </p>
      <PageTitle
        title={`${t.route?.source?.name ?? "—"} → ${t.route?.destination?.name ?? "—"}`}
        subtitle={`${t.buses?.registration_number ?? ""} · ${t.operators?.name ?? ""} · departs ${fmtDateTime(t.departure_at)}`}
      />
      <div className="mb-4"><Badge status={t.status} /></div>

      <LiveRefresh tripId={id} />

      <div className="mb-6 grid max-w-3xl grid-cols-2 gap-3 md:grid-cols-4">
        <StatCard label="Occupancy" value={`${m.counts.occupancy_pct}%`} />
        <StatCard label="Confirmed seats" value={`${m.counts.booked + m.counts.boarded} / ${m.counts.total}`} />
        <StatCard label="Held at checkout" value={m.counts.held} />
        <StatCard label="Blocked" value={m.counts.blocked} />
      </div>

      <SectionHeader title="Seat layout" />
      <SeatStatusMap layout={m.layout} seats={m.seats} />

      {s && (
        <div className="mt-6 max-w-3xl">
          <SectionHeader title="Bookings" />
          <p className="text-sm text-text-secondary">
            {s.confirmed_seats} confirmed · {s.pending_reservations} pending · {s.available_seats} available · {s.cancelled_bookings} cancelled booking(s)
          </p>
        </div>
      )}

      <div className="mt-6 max-w-3xl">
        <SectionHeader title="Tracking" />
        <div className="rounded-lg border border-border bg-surface p-4 text-sm">
          <p className="font-medium">{tr?.label}</p>
          <p className="mt-1 text-text-secondary">
            Source: {tr?.source ?? "—"}
            {tr?.recorded_at ? ` · last update ${fmtDateTime(tr.recorded_at)}` : ""}
            {tr?.latitude != null ? ` · ${tr.latitude}, ${tr.longitude}` : ""}
            {tr?.confidence != null ? ` · confidence ${Math.round(tr.confidence * 100)}%` : ""}
          </p>
          {tr?.is_estimate && <p className="mt-1 text-xs text-warning">Estimated from consenting passengers — not a confirmed GPS position.</p>}
          {tr?.device && (
            <p className="mt-1 text-xs text-text-tertiary">
              Device: {tr.device.name ?? "tracker"} · {tr.device.activation_status} · {tr.device.connection_status}
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
