import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { inr } from "@/lib/money";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../../notice";
import { confirmBankResult } from "../actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const EXPLAIN: Record<string, string> = {
  matched: "Matches an exported batch (amount, account and UTR check out).",
  unmatched: "No batch has this reference.",
  amount_mismatch: "The amount differs from the batch's net payable.",
  account_mismatch: "The account digits differ from the frozen beneficiary.",
  duplicate_utr: "This UTR was already used by another payment (or appears twice in the file).",
  duplicate_row: "The same batch appears more than once in this file.",
  already_paid: "That batch is already paid.",
  batch_not_exported: "That batch has not been exported (or is not awaiting a result).",
  missing_utr: "A successful payment needs the bank's UTR.",
  invalid_row: "The row could not be read (reference, amount or status).",
};

export default async function BankResultDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { id } = await params;
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const { data: imp } = await supabase.from("bank_result_imports").select("*").eq("id", id).maybeSingle();
  if (!imp) notFound();
  const i: any = imp;
  const { data: rows } = await supabase
    .from("bank_result_rows")
    .select("id, line_no, batch_reference, account_digits, amount_cents, utr, bank_status, failure_reason, paid_on, match_status, applied, settlements(id, net_payable_cents, operators(name))")
    .eq("import_id", id)
    .order("line_no");
  const matched = (rows as any[] | null)?.filter((r) => r.match_status === "matched").length ?? 0;
  const problems = (rows?.length ?? 0) - matched;

  return (
    <div>
      <PageTitle title={`Bank result: ${i.file_name ?? id}`} subtitle="Review how each row matched, then confirm. Only matched rows change anything; the rest go to the exception queue." />
      <FinanceNav current="/finance/bank-results" />
      <Notice error={error} ok={ok} />
      <p className="mb-4"><Link href="/finance/bank-results" className="text-sm text-primary hover:underline">← Bank results</Link></p>

      <div className="mb-6 flex flex-wrap items-center gap-4">
        <Badge status={i.status} />
        <span className="text-sm text-text-secondary">{rows?.length ?? 0} rows · {matched} matched · {problems} will become exceptions</span>
        <span className="font-mono text-xs text-text-tertiary">sha256 {String(i.file_hash).slice(0, 16)}…</span>
      </div>

      {i.status === "previewed" && (
        <form action={confirmBankResult} className="mb-6">
          <input type="hidden" name="id" value={id} />
          <ConfirmButton message={`Apply this bank result? ${matched} matched row(s) will mark batches paid or failed. This cannot be undone here. The admin who approved a batch cannot confirm its payment.`}>
            Confirm and apply (step 2 of 2)
          </ConfirmButton>
        </form>
      )}
      {i.status === "confirmed" && <p className="mb-6 text-sm text-text-secondary">Confirmed {fmtDateTime(i.confirmed_at)}. Re-uploading the same file changes nothing.</p>}

      <SectionHeader title="Rows" />
      <Table>
        <thead><tr><Th>#</Th><Th>Batch reference</Th><Th>Operator</Th><Th>Bank status</Th><Th>Amount</Th><Th>UTR</Th><Th>Account</Th><Th>Result</Th></tr></thead>
        <tbody>
          {(rows as any[] | null)?.map((r) => (
            <tr key={r.id}>
              <Td>{r.line_no}</Td>
              <Td className="font-mono">{r.batch_reference ?? "—"}</Td>
              <Td>{r.settlements?.operators?.name ?? "—"}</Td>
              <Td>{r.bank_status ? <Badge status={r.bank_status === "success" ? "captured" : "failed"} /> : "—"}{r.failure_reason && <div className="mt-1 text-xs text-error">{r.failure_reason}</div>}</Td>
              <Td>{inr(r.amount_cents)}{r.settlements && r.amount_cents !== r.settlements.net_payable_cents && <div className="text-xs text-text-tertiary">batch {inr(r.settlements.net_payable_cents)}</div>}</Td>
              <Td className="font-mono text-xs">{r.utr ?? "—"}</Td>
              <Td className="font-mono text-xs">{r.account_digits ? `…${r.account_digits}` : "—"}</Td>
              <Td>
                <Badge status={r.match_status === "matched" ? "verified" : "failed"} />
                <div className="mt-1 max-w-xs text-xs text-text-tertiary">{r.match_status.replace(/_/g, " ")}: {EXPLAIN[r.match_status]}</div>
                {r.applied && <div className="text-xs text-success">applied</div>}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!rows?.length && <EmptyState message="No rows." />}
    </div>
  );
}
