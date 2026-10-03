import { createClient } from "@/lib/supabase/server";
import { EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import GlobalSettingsForm, { type GlobalSettings } from "./global-settings-form";
import RouteWindowTable, { type RouteWindowRow } from "./route-window-table";

type AuditRow = {
  id: string;
  action: string;
  entity_type: string;
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
  created_at: string;
  profiles: { full_name: string | null; email: string | null } | null;
};

function describe(a: AuditRow): string {
  const b = a.before ?? {};
  const n = a.after ?? {};
  if (a.entity_type === "route_booking_window") {
    return `Route window ${b.advance_days ?? "—"} → ${n.advance_days ?? "removed"} days${n.override_enabled === false ? " (disabled)" : ""}`;
  }
  if (a.entity_type === "operator_booking_window") {
    return `Operator window ${b.advance_days ?? "—"} → ${n.advance_days ?? "removed"} days`;
  }
  return `Global default ${b.default_advance_days ?? "—"} → ${n.default_advance_days ?? "—"} days (min ${n.min_advance_days}, max ${n.max_advance_days})`;
}

export default async function BookingWindowsPage() {
  const supabase = await createClient();

  const [{ data: settings }, { data: routes }, { data: audit }] = await Promise.all([
    supabase.from("scheduling_settings").select("*").eq("id", true).single<GlobalSettings>(),
    supabase.rpc("admin_route_booking_windows"),
    supabase
      .from("audit_logs")
      .select("id, action, entity_type, before, after, created_at, profiles:actor_profile_id(full_name, email)")
      .in("entity_type", ["route_booking_window", "operator_booking_window", "scheduling_settings"])
      .order("created_at", { ascending: false })
      .limit(30)
      .returns<AuditRow[]>(),
  ]);

  return (
    <div className="space-y-10">
      <PageTitle
        title="Booking Window Configuration"
        subtitle="How far ahead each route can be booked. Operators configure their recurring schedule once; the backend publishes departures inside this window automatically."
      />

      <section>
        <SectionHeader title="Global default & rules" />
        {settings ? <GlobalSettingsForm settings={settings} /> : <EmptyState message="Scheduling settings not found." />}
      </section>

      <section>
        <SectionHeader title="Route-specific advance booking" />
        <p className="mb-3 text-sm text-text-secondary">
          Precedence: route override → admin-approved operator override (if enabled globally) → global default. All values are clamped to the global minimum/maximum.
        </p>
        <RouteWindowTable rows={(routes as RouteWindowRow[] | null) ?? []} />
      </section>

      <section>
        <SectionHeader title="Change history" />
        <Table>
          <thead>
            <tr>
              <Th>When</Th>
              <Th>Admin</Th>
              <Th>Change</Th>
            </tr>
          </thead>
          <tbody>
            {audit?.map((a) => (
              <tr key={a.id}>
                <Td>{new Date(a.created_at).toLocaleString()}</Td>
                <Td>{a.profiles?.full_name ?? a.profiles?.email ?? "system"}</Td>
                <Td>{describe(a)}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!audit?.length && <EmptyState message="No configuration changes yet." />}
      </section>
    </div>
  );
}
