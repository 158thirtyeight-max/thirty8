import Link from "next/link";
import { requirePlatformAdmin } from "@/lib/auth";
import SignOutButton from "./sign-out-button";

const NAV_ITEMS = [
  { href: "/dashboard", label: "Dashboard" },
  { href: "/operators", label: "Operators" },
  { href: "/users", label: "Users" },
  { href: "/bookings", label: "Bookings" },
  { href: "/shipments", label: "Shipments" },
  { href: "/refunds", label: "Refunds" },
  { href: "/revenue", label: "Revenue" },
  { href: "/audit-logs", label: "Audit logs" },
];

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const { user } = await requirePlatformAdmin();

  return (
    <div className="flex min-h-screen bg-background text-text-primary">
      <aside className="flex w-56 shrink-0 flex-col border-r border-border bg-surface p-4">
        <div className="mb-6 px-2">
          <h1 className="text-lg font-semibold text-text-primary">Thirty8 Admin</h1>
          <p className="mt-0.5 truncate text-xs text-text-tertiary">{user.email}</p>
        </div>
        <nav className="flex flex-1 flex-col gap-1">
          {NAV_ITEMS.map((item) => (
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
