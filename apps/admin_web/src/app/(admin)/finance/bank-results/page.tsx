import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { inr } from "@/lib/money";
import { Badge, Button, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { FinanceNav, Notice } from "../notice";
import { previewBankResult } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function BankResultsPage({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const [{ data: imports }, { data: exports }] = await Promise.all([
    supabase.from("bank_result_imports").select("id, file_name, status, row_count, summary, uploaded_at, confirmed_at").order("uploaded_at", { ascending: false }).limit(50),
    supabase.rpc("admin_list_settlement_exports"),
  ]);

  return (
    <div>
      <PageTitle title="Bank results & payment files" subtitle="Download the payment file for SBI, then upload the bank's result here. Nothing is marked paid without a matched row and its UTR." />
      <FinanceNav current="/finance/bank-results" />
      <Notice error={error} ok={ok} />

      <section className="mb-8 max-w-2xl rounded-lg border border-border bg-surface p-4">
        <SectionHeader title="Upload a bank result (step 1 of 2: preview)" />
        <p className="mb-3 text-sm text-text-secondary">
          CSV with a batch reference (the narration/reference from our file), amount, status (success / failed) and the bank&apos;s UTR; account digits and date are used when present.
          The preview checks every row against the exported batches and applies nothing.
        </p>
        <form action={previewBankResult} className="flex flex-wrap items-center gap-3">
          <input type="file" name="file" accept=".csv,text/csv" required className="text-sm" />
          <Button type="submit">Preview</Button>
        </form>
      </section>

      <SectionHeader title="Uploaded results" />
      <div className="mb-8">
        <Table>
          <thead><tr><Th>File</Th><Th>Status</Th><Th>Rows</Th><Th>Match summary</Th><Th>Uploaded</Th><Th>Confirmed</Th></tr></thead>
          <tbody>
            {(imports as any[] | null)?.map((i) => (
              <tr key={i.id}>
                <Td><Link className="text-primary hover:underline" href={`/finance/bank-results/${i.id}`}>{i.file_name ?? i.id.slice(0, 8)}</Link></Td>
                <Td><Badge status={i.status} /></Td>
                <Td>{i.row_count}</Td>
                <Td className="text-xs">{Object.entries(i.summary ?? {}).map(([k, v]) => `${k.replace(/_/g, " ")}: ${v}`).join(" · ")}</Td>
                <Td>{fmtDateTime(i.uploaded_at)}</Td>
                <Td>{i.confirmed_at ? fmtDateTime(i.confirmed_at) : "—"}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!imports?.length && <EmptyState message="No bank result has been uploaded." />}
      </div>

      <SectionHeader title="Payment files exported to SBI" />
      <Table>
        <thead><tr><Th>File</Th><Th>Batches</Th><Th>Total</Th><Th>SHA-256</Th><Th>Layout</Th><Th>Created</Th></tr></thead>
        <tbody>
          {(exports as any[] | null)?.map((e) => (
            <tr key={e.export_id}>
              <Td><a className="text-primary hover:underline" href={`/finance/settlements/export/${e.export_id}`}>{e.file_name}</a></Td>
              <Td>{e.row_count}</Td>
              <Td>{inr(e.total_cents)}</Td>
              <Td className="font-mono text-xs">{String(e.sha256).slice(0, 16)}…</Td>
              <Td>{e.template_confirmed ? <Badge status="verified" /> : <span className="text-xs text-warning">layout not confirmed with SBI</span>}</Td>
              <Td>{fmtDateTime(e.created_at)}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!(exports as any[] | null)?.length && <EmptyState message="No payment file has been exported." />}
    </div>
  );
}
