import { createClient } from "@/lib/supabase/server";
import { PageTitle, StatCard, Table, Td, Th } from "@/components/ui";

export default async function RevenuePage() {
  const supabase = await createClient();

  const [{ data: captured }, { data: refunded }] = await Promise.all([
    supabase.from("payments").select("amount_cents, captured_at").eq("status", "captured"),
    supabase.from("refunds").select("amount_cents").eq("status", "processed"),
  ]);

  const totalCaptured = (captured ?? []).reduce((sum, p) => sum + (p.amount_cents ?? 0), 0);
  const totalRefunded = (refunded ?? []).reduce((sum, r) => sum + (r.amount_cents ?? 0), 0);

  const byDay = new Map<string, number>();
  for (const p of captured ?? []) {
    if (!p.captured_at) continue;
    const day = p.captured_at.slice(0, 10);
    byDay.set(day, (byDay.get(day) ?? 0) + p.amount_cents);
  }
  const dailyRows = [...byDay.entries()].sort((a, b) => (a[0] < b[0] ? 1 : -1)).slice(0, 14);

  return (
    <div>
      <PageTitle title="Revenue" subtitle="Gross revenue from captured payments, platform-wide" />
      <div className="mb-8 grid grid-cols-1 gap-4 md:grid-cols-3">
        <StatCard label="Gross captured" value={`₹${(totalCaptured / 100).toLocaleString("en-IN")}`} />
        <StatCard label="Refunded" value={`₹${(totalRefunded / 100).toLocaleString("en-IN")}`} />
        <StatCard label="Net revenue" value={`₹${((totalCaptured - totalRefunded) / 100).toLocaleString("en-IN")}`} />
      </div>

      <h3 className="mb-3 text-sm font-medium text-slate-300">Last 14 days with activity</h3>
      <Table>
        <thead>
          <tr>
            <Th>Date</Th>
            <Th>Captured</Th>
          </tr>
        </thead>
        <tbody>
          {dailyRows.map(([day, amount]) => (
            <tr key={day}>
              <Td>{new Date(day).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" })}</Td>
              <Td>₹{(amount / 100).toLocaleString("en-IN")}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!dailyRows.length && <p className="mt-2 text-sm text-slate-500">No captured payments yet.</p>}
    </div>
  );
}
