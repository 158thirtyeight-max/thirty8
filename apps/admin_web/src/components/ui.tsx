import type { ButtonHTMLAttributes, ReactNode } from "react";

export function PageTitle({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div className="mb-6">
      <h2 className="text-xl font-semibold text-text-primary">{title}</h2>
      {subtitle && <p className="mt-1 text-sm text-text-secondary">{subtitle}</p>}
    </div>
  );
}

export function StatCard({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-lg border border-border bg-surface p-5 shadow-sm">
      <p className="text-sm text-text-secondary">{label}</p>
      <p className="mt-1 text-2xl font-semibold text-text-primary">{value}</p>
    </div>
  );
}

export function Table({ children }: { children: React.ReactNode }) {
  return (
    <div className="overflow-x-auto rounded-lg border border-border">
      <table className="w-full text-left text-sm">{children}</table>
    </div>
  );
}

export function Th({ children }: { children?: React.ReactNode }) {
  return <th className="border-b border-border bg-surface px-4 py-3 font-medium text-text-secondary">{children}</th>;
}

export function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`border-b border-divider px-4 py-3 text-text-primary ${className}`}>{children}</td>;
}

const BADGE_COLORS: Record<string, string> = {
  approved: "bg-success/15 text-success",
  active: "bg-success/15 text-success",
  captured: "bg-success/15 text-success",
  confirmed: "bg-success/15 text-success",
  delivered: "bg-success/15 text-success",
  verified: "bg-success/15 text-success",
  submitted: "bg-warning/15 text-warning",
  under_review: "bg-warning/15 text-warning",
  changes_requested: "bg-warning/15 text-warning",
  legacy: "bg-warning/15 text-warning",
  pending: "bg-warning/15 text-warning",
  draft: "bg-warning/15 text-warning",
  processing: "bg-warning/15 text-warning",
  rejected: "bg-error/15 text-error",
  suspended: "bg-error/15 text-error",
  cancelled: "bg-error/15 text-error",
  failed: "bg-error/15 text-error",
};

export function Badge({ status }: { status: string }) {
  const color = BADGE_COLORS[status] ?? "bg-text-tertiary/15 text-text-secondary";
  return <span className={`rounded-pill px-2.5 py-1 text-xs font-medium capitalize ${color}`}>{status.replace(/_/g, " ")}</span>;
}

export function EmptyState({ message }: { message: string }) {
  return <p className="px-4 py-8 text-center text-sm text-text-tertiary">{message}</p>;
}

export function LoadingState({ message = "Loading…" }: { message?: string }) {
  return (
    <div className="flex flex-col items-center gap-3 px-4 py-10 text-sm text-text-secondary">
      <span className="h-5 w-5 animate-spin rounded-full border-2 border-border border-t-primary" />
      {message}
    </div>
  );
}

export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="flex flex-col items-center gap-3 px-4 py-10 text-center">
      <p className="text-sm text-error">{message}</p>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="rounded-md border border-border px-3 py-1.5 text-sm font-medium text-text-primary transition hover:border-primary hover:text-primary"
        >
          Retry
        </button>
      )}
    </div>
  );
}

export function SectionHeader({ title, action }: { title: string; action?: ReactNode }) {
  return (
    <div className="mb-3 flex items-center justify-between">
      <h3 className="text-base font-semibold text-text-primary">{title}</h3>
      {action}
    </div>
  );
}

type ButtonVariant = "primary" | "secondary" | "outline" | "ghost" | "destructive";

const BUTTON_VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: "bg-primary text-white hover:bg-primary-dark",
  secondary: "bg-secondary text-white hover:opacity-90",
  destructive: "bg-error text-white hover:opacity-90",
  outline: "border border-border text-text-primary hover:border-primary hover:text-primary",
  ghost: "text-primary hover:bg-primary/10",
};

/** The one button every admin screen should reach for — mirrors the Flutter `AppButton` variants (see DESIGN_SYSTEM.md). */
export function Button({
  variant = "primary",
  className = "",
  children,
  ...rest
}: { variant?: ButtonVariant; children: ReactNode } & ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      className={`rounded-md px-4 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-40 ${BUTTON_VARIANT_CLASSES[variant]} ${className}`}
      {...rest}
    >
      {children}
    </button>
  );
}
