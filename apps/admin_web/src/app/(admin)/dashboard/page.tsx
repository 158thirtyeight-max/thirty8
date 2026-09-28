import { createClient } from "@/lib/supabase/server";
import { PageTitle, StatCard } from "@/components/ui";

export default async function DashboardPage() {
  const supabase = await createClient();

  const [
    { count: pendingOperators },
    { count: totalOperators },
    { count: totalBookings },
    { count: totalShipments },
    { count: pendingRefunds },
    { data: revenueRows },
  ] = await Promise.all([
    supabase.from("operators").select("id", { count: "exact", head: true }).eq("status", "pending"),
    supabase.from("operators").select("id", { count: "exact", head: true }),
    supabase.from("bookings").select("id", { count: "exact", head: true }),
    supabase.from("cargo_shipments").select("id", { count: "exact", head: true }),
    supabase.from("refunds").select("id", { count: "exact", head: true }).eq("status", "pending"),
    supabase.from("payments").select("amount_cents").eq("status", "captured"),
  ]);

  const totalRevenueCents = (revenueRows ?? []).reduce((sum, row) => sum + (row.amount_cents ?? 0), 0);

  return (
    <div>
      <PageTitle title="Dashboard" subtitle="Platform-wide overview" />
      <div className="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-4">
        <StatCard label="Operators pending approval" value={pendingOperators ?? 0} />
        <StatCard label="Total operators" value={totalOperators ?? 0} />
        <StatCard label="Total bookings" value={totalBookings ?? 0} />
        <StatCard label="Total shipments" value={totalShipments ?? 0} />
        <StatCard label="Refunds awaiting action" value={pendingRefunds ?? 0} />
        <StatCard label="Gross revenue (captured)" value={`₹${(totalRevenueCents / 100).toLocaleString("en-IN")}`} />
      </div>
    </div>
  );
}
