export function PageTitle({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div className="mb-6">
      <h2 className="text-xl font-semibold text-white">{title}</h2>
      {subtitle && <p className="mt-1 text-sm text-slate-400">{subtitle}</p>}
    </div>
  );
}

export function StatCard({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900 p-5">
      <p className="text-sm text-slate-400">{label}</p>
      <p className="mt-1 text-2xl font-semibold text-white">{value}</p>
    </div>
  );
}

export function Table({ children }: { children: React.ReactNode }) {
  return (
    <div className="overflow-x-auto rounded-xl border border-slate-800">
      <table className="w-full text-left text-sm">{children}</table>
    </div>
  );
}

export function Th({ children }: { children?: React.ReactNode }) {
  return <th className="border-b border-slate-800 bg-slate-900 px-4 py-3 font-medium text-slate-400">{children}</th>;
}

export function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`border-b border-slate-800/60 px-4 py-3 text-slate-200 ${className}`}>{children}</td>;
}

const BADGE_COLORS: Record<string, string> = {
  approved: "bg-emerald-950 text-emerald-300",
  active: "bg-emerald-950 text-emerald-300",
  captured: "bg-emerald-950 text-emerald-300",
  confirmed: "bg-emerald-950 text-emerald-300",
  delivered: "bg-emerald-950 text-emerald-300",
  pending: "bg-amber-950 text-amber-300",
  draft: "bg-amber-950 text-amber-300",
  processing: "bg-amber-950 text-amber-300",
  rejected: "bg-red-950 text-red-300",
  suspended: "bg-red-950 text-red-300",
  cancelled: "bg-red-950 text-red-300",
  failed: "bg-red-950 text-red-300",
};

export function Badge({ status }: { status: string }) {
  const color = BADGE_COLORS[status] ?? "bg-slate-800 text-slate-300";
  return <span className={`rounded-full px-2.5 py-1 text-xs font-medium capitalize ${color}`}>{status.replace(/_/g, " ")}</span>;
}

export function EmptyState({ message }: { message: string }) {
  return <p className="px-4 py-8 text-center text-sm text-slate-500">{message}</p>;
}
