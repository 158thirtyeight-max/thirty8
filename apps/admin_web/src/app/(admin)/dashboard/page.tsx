import { createClient } from "@/lib/supabase/server";
import { PageTitle, StatCard } from "@/components/ui";

export default async function DashboardPage() {
  const supabase = await createClient();

  const [
    { count: pendingOperators },
    { count: busesInReview },
    { count: legacyBuses },
    { count: docsExpired },
    { count: docsExpiringSoon },
    { count: totalOperators },
    { count: totalBookings },
    { count: totalShipments },
    { count: pendingRefunds },
    { data: revenueRows },
  ] = await Promise.all([
    supabase.from("operators").select("id", { count: "exact", head: true }).in("application_status", ["submitted", "under_review"]),
    supabase
      .from("buses")
      .select("id", { count: "exact", head: true })
      .or("lifecycle_status.in.(submitted,under_review),legacy_migration_status.in.(submitted,under_review)"),
    supabase.from("buses").select("id", { count: "exact", head: true }).eq("is_legacy", true),
    supabase.from("bus_document_expiry").select("id", { count: "exact", head: true }).eq("expiry_state", "expired"),
    supabase.from("bus_document_expiry").select("id", { count: "exact", head: true }).eq("expiry_state", "expiring_soon"),
    supabase.from("operators").select("id", { count: "exact", head: true }),
    supabase.from("bookings").select("id", { count: "exact", head: true }),
    supabase.from("cargo_shipments").select("id", { count: "exact", head: true }),
    supabase.from("refunds").select("id", { count: "exact", head: true }).in("status", ["requested", "approved", "submitted_to_provider"]),
    supabase.from("payments").select("amount_cents").eq("status", "captured"),
  ]);

  const totalRevenueCents = (revenueRows ?? []).reduce((sum, row) => sum + (row.amount_cents ?? 0), 0);

  return (
    <div>
      <PageTitle title="Dashboard" subtitle="Platform-wide overview" />
      <div className="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-4">
        <StatCard label="Operator applications to review" value={pendingOperators ?? 0} />
        <StatCard label="Buses awaiting review" value={busesInReview ?? 0} />
        <StatCard label="Legacy buses to migrate" value={legacyBuses ?? 0} />
        <StatCard label="Bus documents expired" value={docsExpired ?? 0} />
        <StatCard label="Bus documents expiring in 30 days" value={docsExpiringSoon ?? 0} />
        <StatCard label="Total operators" value={totalOperators ?? 0} />
        <StatCard label="Total bookings" value={totalBookings ?? 0} />
        <StatCard label="Total shipments" value={totalShipments ?? 0} />
        <StatCard label="Refunds awaiting action" value={pendingRefunds ?? 0} />
        <StatCard label="Gross revenue (captured)" value={`₹${(totalRevenueCents / 100).toLocaleString("en-IN")}`} />
      </div>
    </div>
  );
}
