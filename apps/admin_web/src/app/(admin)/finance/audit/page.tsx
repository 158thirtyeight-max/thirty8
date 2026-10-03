import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";
import { FinanceNav } from "../notice";

/* eslint-disable @typescript-eslint/no-explicit-any */

// action prefixes written by the finance RPCs (every one records who, what, before/after)
const GROUPS: Record<string, { label: string; prefixes: string[] }> = {
  all: { label: "All financial", prefixes: ["refund", "refund_policy", "settlement", "settlement_export", "bank_import", "commission", "payment_profile", "payout_hold", "ledger", "reconciliation", "recovery", "earning", "platform_setting"] },
  refunds: { label: "Refunds & policies", prefixes: ["refund", "refund_policy", "recovery"] },
  settlements: { label: "Settlements & bank", prefixes: ["settlement", "settlement_export", "bank_import", "payment_profile", "payout_hold"] },
  commission: { label: "Commission & settings", prefixes: ["commission", "platform_setting"] },
  ledger: { label: "Ledger & reconciliation", prefixes: ["ledger", "reconciliation", "earning"] },
};

export default async function FinanceAuditPage({ searchParams }: { searchParams: Promise<{ group?: string }> }) {
  const { group } = await searchParams;
  const key = group && GROUPS[group] ? group : "all";
  const supabase = await createClient();
  const filter = GROUPS[key].prefixes.map((p) => `action.like.${p}.*`).join(",");
  const { data: logs } = await supabase
    .from("audit_logs")
    .select("id, action, entity_type, entity_id, before, after, created_at, profiles:actor_profile_id(full_name, email)")
    .or(filter)
    .order("created_at", { ascending: false })
    .limit(200);

  return (
    <div>
      <PageTitle title="Financial audit log" subtitle="Every financial action: who did it, when, and what changed. Passwords, secrets and full bank account numbers are never recorded here." />
      <FinanceNav current="/finance/audit" />
      <div className="mb-4 flex flex-wrap gap-2">
        {Object.entries(GROUPS).map(([k, g]) => (
          <Link key={k} href={k === "all" ? "/finance/audit" : `/finance/audit?group=${k}`}
            className={`rounded-pill px-3 py-1 text-sm ${key === k ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}>{g.label}</Link>
        ))}
      </div>
      <Table>
        <thead><tr><Th>When</Th><Th>Who</Th><Th>Action</Th><Th>Record</Th><Th>Before → after</Th></tr></thead>
        <tbody>
          {(logs as any[] | null)?.map((l) => (
            <tr key={l.id} className="align-top">
              <Td className="whitespace-nowrap">{fmtDateTime(l.created_at)}</Td>
              <Td>{l.profiles?.full_name ?? l.profiles?.email ?? "system"}</Td>
              <Td className="font-mono text-xs">{l.action}</Td>
              <Td className="font-mono text-xs">{l.entity_type}<div className="max-w-[12rem] truncate text-text-tertiary">{l.entity_id}</div></Td>
              <Td className="max-w-md font-mono text-xs text-text-tertiary">
                {l.before ? <div className="truncate">{JSON.stringify(l.before)}</div> : null}
                {l.after ? <div className="truncate text-text-secondary">→ {JSON.stringify(l.after)}</div> : null}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!logs?.length && <EmptyState message="No financial activity recorded." />}
    </div>
  );
}
