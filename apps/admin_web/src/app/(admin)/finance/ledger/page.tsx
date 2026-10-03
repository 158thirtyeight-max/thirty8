import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { inr } from "@/lib/money";
import { EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { recordProviderSettlement } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function LedgerPage({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const [{ data: balances }, { data: journals }] = await Promise.all([
    supabase.from("ledger_account_balances").select("account_code, account_name, account_type, operator_id, debit_cents, credit_cents, balance_cents").is("operator_id", null),
    supabase.from("ledger_journals").select("id, event_type, description, total_cents, posted_at, source_event_key, reverses_journal_id").order("posted_at", { ascending: false }).limit(50),
  ]);
  const { data: perOperator } = await supabase
    .from("ledger_account_balances")
    .select("account_code, balance_cents, operator_id")
    .not("operator_id", "is", null);
  const { data: operators } = await supabase.from("operators").select("id, name");
  const { data: providerSettlements } = await supabase.from("provider_settlements").select("id, provider_reference, amount_cents, settled_on, note, recorded_at").order("recorded_at", { ascending: false }).limit(20);
  const name = new Map((operators as any[] | null)?.map((o) => [o.id, o.name]));
  const totalDebits = (balances as any[] | null)?.reduce((s, b) => s + Number(b.debit_cents), 0) ?? 0;
  const totalCredits = (balances as any[] | null)?.reduce((s, b) => s + Number(b.credit_cents), 0) ?? 0;

  return (
    <div>
      <PageTitle title="Financial ledger" subtitle="Append-only double-entry journals. Entries are never edited or deleted; corrections are reversal journals." />
      <FinanceNav current="/finance/ledger" />
      <Notice error={error} ok={ok} />
      <SectionHeader title="Account balances (platform level)" />
      <div className="mb-3">
        <Table>
          <thead><tr><Th>Account</Th><Th>Type</Th><Th>Debits</Th><Th>Credits</Th><Th>Balance</Th></tr></thead>
          <tbody>
            {(balances as any[] | null)?.map((b) => (
              <tr key={b.account_code}><Td>{b.account_name}<div className="font-mono text-xs text-text-tertiary">{b.account_code}</div></Td><Td className="capitalize">{b.account_type}</Td><Td>{inr(b.debit_cents)}</Td><Td>{inr(b.credit_cents)}</Td><Td className="font-medium">{inr(b.balance_cents)}</Td></tr>
            ))}
          </tbody>
        </Table>
      </div>
      <p className="mb-8 text-xs text-text-tertiary">
        Platform-level totals: debits {inr(totalDebits)} · credits {inr(totalCredits)} (per-operator lines are listed separately below). The settlement bank shows payouts out and Razorpay settlements in once you record them below.
      </p>

      <SectionHeader title="Money settled by Razorpay to the bank" />
      <section className="mb-8 max-w-3xl rounded-lg border border-border bg-surface p-4">
        <p className="mb-3 text-sm text-text-secondary">
          When Razorpay settles collected payments to your bank account, record it here from the Razorpay settlement report (one entry per Razorpay settlement id; recording the same id again changes nothing).
          This moves the amount from <b>Razorpay clearing</b> to the <b>settlement bank</b> in the ledger.
        </p>
        <form action={recordProviderSettlement} className="flex flex-wrap items-end gap-2">
          <label className="text-sm text-text-secondary">Razorpay settlement id<br /><input name="reference" required placeholder="setl_..." className={inputClass} /></label>
          <label className="text-sm text-text-secondary">Amount (₹)<br /><input name="amount" required inputMode="decimal" className={`${inputClass} w-32`} /></label>
          <label className="text-sm text-text-secondary">Settled on<br /><input type="date" name="settled_on" className={inputClass} /></label>
          <label className="text-sm text-text-secondary">Note<br /><input name="note" className={inputClass} /></label>
          <ConfirmButton message="Record this Razorpay settlement in the ledger? It cannot be edited afterwards (only reversed).">Record</ConfirmButton>
        </form>
        {(providerSettlements as any[] | null)?.length ? (
          <div className="mt-4">
            <Table>
              <thead><tr><Th>Razorpay settlement</Th><Th>Amount</Th><Th>Settled on</Th><Th>Recorded</Th></tr></thead>
              <tbody>
                {(providerSettlements as any[]).map((p) => (
                  <tr key={p.id}><Td className="font-mono text-xs">{p.provider_reference}{p.note && <div className="font-sans text-text-tertiary">{p.note}</div>}</Td><Td>{inr(p.amount_cents)}</Td><Td>{p.settled_on}</Td><Td>{fmtDateTime(p.recorded_at)}</Td></tr>
                ))}
              </tbody>
            </Table>
          </div>
        ) : null}
      </section>

      <SectionHeader title="Per operator" />
      <div className="mb-8">
        <Table>
          <thead><tr><Th>Operator</Th><Th>Account</Th><Th>Balance</Th></tr></thead>
          <tbody>
            {(perOperator as any[] | null)?.filter((r) => Number(r.balance_cents) !== 0).map((r, i) => (
              <tr key={i}><Td>{name.get(r.operator_id) ?? r.operator_id}</Td><Td className="font-mono text-xs">{r.account_code}</Td><Td>{inr(r.balance_cents)}</Td></tr>
            ))}
          </tbody>
        </Table>
      </div>

      <SectionHeader title="Latest journals" />
      <Table>
        <thead><tr><Th>Posted</Th><Th>Event</Th><Th>Amount</Th><Th>Source key</Th></tr></thead>
        <tbody>
          {(journals as any[] | null)?.map((j) => (
            <tr key={j.id}>
              <Td>{fmtDateTime(j.posted_at)}</Td>
              <Td>{j.event_type}{j.reverses_journal_id && <span className="ml-1 text-xs text-warning">(reversal)</span>}<div className="max-w-md truncate text-xs text-text-tertiary">{j.description}</div></Td>
              <Td>{inr(j.total_cents)}</Td>
              <Td className="max-w-xs truncate font-mono text-xs text-text-tertiary">{j.source_event_key}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!journals?.length && <EmptyState message="Nothing has been posted yet." />}
    </div>
  );
}
