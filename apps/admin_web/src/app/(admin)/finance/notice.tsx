import Link from "next/link";

/** Success / failure banner driven by ?ok= and ?error= (set by the server actions). */
export function Notice({ error, ok }: { error?: string; ok?: string }) {
  return (
    <>
      {error && <p className="mb-4 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}
      {ok && <p className="mb-4 rounded-md border border-success/40 bg-success/10 px-4 py-3 text-sm text-success">{ok}</p>}
    </>
  );
}

export function FinanceNav({ current }: { current: string }) {
  const links = [
    ["/finance", "Dashboard"],
    ["/finance/payments", "Payments"],
    ["/finance/earnings", "Earnings"],
    ["/finance/settlements", "Settlements"],
    ["/finance/bank-results", "Bank results"],
    ["/refunds", "Refunds"],
    ["/finance/refund-policies", "Refund policies"],
    ["/finance/recoveries", "Recoveries"],
    ["/finance/payout-profiles", "Payout profiles"],
    ["/finance/commission", "Commission"],
    ["/finance/reconciliation", "Reconciliation"],
    ["/finance/ledger", "Ledger"],
    ["/finance/audit", "Audit"],
  ];
  return (
    <div className="mb-5 flex flex-wrap gap-2">
      {links.map(([href, label]) => (
        <Link
          key={href}
          href={href}
          className={`rounded-pill px-3 py-1 text-sm transition ${
            current === href ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"
          }`}
        >
          {label}
        </Link>
      ))}
    </div>
  );
}
