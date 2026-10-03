import Link from "next/link";
import { requirePlatformAdmin } from "@/lib/auth";
import SignOutButton from "./sign-out-button";

const TOP_ITEMS = [
  { href: "/dashboard", label: "Dashboard" },
  { href: "/operators", label: "Operators" },
  { href: "/buses", label: "Buses" },
];

const OPS_ITEMS = [
  { href: "/users", label: "Users" },
  { href: "/bookings", label: "Bookings" },
  { href: "/shipments", label: "Shipments" },
  { href: "/trips", label: "Trips" },
  { href: "/gps-devices", label: "GPS devices" },
  { href: "/revenue", label: "Revenue" },
  { href: "/audit-logs", label: "Audit logs" },
  { href: "/settings/document-requirements", label: "Requirements" },
];

const FINANCE_ITEMS = [
  { href: "/finance", label: "Finance dashboard" },
  { href: "/finance/payments", label: "Payments" },
  { href: "/finance/earnings", label: "Operator earnings" },
  { href: "/finance/settlements", label: "Weekly settlements" },
  { href: "/finance/bank-results", label: "Bank results" },
  { href: "/refunds", label: "Refund requests" },
  { href: "/finance/refund-policies", label: "Refund policies" },
  { href: "/finance/recoveries", label: "Operator recoveries" },
  { href: "/finance/payout-profiles", label: "Payout profiles" },
  { href: "/finance/commission", label: "Commission" },
  { href: "/finance/reconciliation", label: "Reconciliation" },
  { href: "/finance/ledger", label: "Ledger" },
  { href: "/finance/audit", label: "Financial audit" },
];

const TRANSPORT_ITEMS = [
  { href: "/locations", label: "Location Management" },
  { href: "/bus-routes", label: "Routes" },
  { href: "/route-approvals", label: "Route Approval Requests" },
  { href: "/route-history", label: "Route History" },
  { href: "/routes", label: "Route Catalog" },
];

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const { user, supabase } = await requirePlatformAdmin();
  const { count: pendingRoutes } = await supabase
    .from("route_revisions")
    .select("id", { count: "exact", head: true })
    .eq("status", "pending_approval");

  return (
    <div className="flex min-h-screen bg-background text-text-primary">
      <aside className="flex w-56 shrink-0 flex-col border-r border-border bg-surface p-4">
        <div className="mb-6 px-2">
          <div className="flex items-center gap-2">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/brand/thirty8-plus-mark.png" alt="" className="h-7 w-7" />
            <span className="text-lg font-semibold text-text-primary">38 <span className="font-normal text-text-tertiary">Admin</span></span>
          </div>
          <p className="mt-1 truncate text-xs text-text-tertiary">Admin · {user.email}</p>
        </div>
        <nav className="flex flex-1 flex-col gap-1">
          {TOP_ITEMS.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="rounded-lg px-3 py-2 text-sm text-text-secondary transition hover:bg-primary/10 hover:text-primary"
            >
              {item.label}
            </Link>
          ))}
          <p className="mt-3 px-3 text-xs font-medium uppercase tracking-wide text-text-tertiary">Transport Management</p>
          {TRANSPORT_ITEMS.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="flex items-center justify-between rounded-lg px-3 py-2 text-sm text-text-secondary transition hover:bg-primary/10 hover:text-primary"
            >
              {item.label}
              {item.href === "/route-approvals" && !!pendingRoutes && (
                <span className="rounded-pill bg-warning/15 px-2 py-0.5 text-xs font-medium text-warning">{pendingRoutes}</span>
              )}
            </Link>
          ))}
          <p className="mt-3 px-3 text-xs font-medium uppercase tracking-wide text-text-tertiary">Finance &amp; Settlements</p>
          {FINANCE_ITEMS.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="rounded-lg px-3 py-2 text-sm text-text-secondary transition hover:bg-primary/10 hover:text-primary"
            >
              {item.label}
            </Link>
          ))}
          <p className="mt-3 px-3 text-xs font-medium uppercase tracking-wide text-text-tertiary">Operations</p>
          {OPS_ITEMS.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="rounded-lg px-3 py-2 text-sm text-text-secondary transition hover:bg-primary/10 hover:text-primary"
            >
              {item.label}
            </Link>
          ))}
        </nav>
        <SignOutButton />
      </aside>
      <main className="flex-1 overflow-x-hidden p-8">{children}</main>
    </div>
  );
}
