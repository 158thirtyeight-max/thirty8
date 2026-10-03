import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { setPayoutHold, setProfileStatus } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const BLOCK: Record<string, string> = {
  payment_profile_missing: "No payout profile yet",
  payment_profile_not_verified: "Not verified",
  bank_details_changed_reverify: "Bank details changed: verify again",
  payout_on_hold: "Payouts on hold",
  operator_not_active: "Operator not active",
};

export default async function PayoutProfilesPage({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const { data, error: rpcError } = await supabase.rpc("admin_list_payment_profiles");
  const profiles = (data as any[] | null) ?? [];

  return (
    <div>
      <PageTitle title="Operator payout profiles" subtitle="Verify an operator's bank details before they can be paid. Account numbers are always masked here; the full number is used only in the frozen settlement file." />
      <FinanceNav current="/finance/payout-profiles" />
      <Notice error={error ?? rpcError?.message} ok={ok} />
      <Table>
        <thead><tr><Th>Operator</Th><Th>Bank account (masked)</Th><Th>Verification</Th><Th>Can be paid?</Th><Th>Actions (full admin)</Th></tr></thead>
        <tbody>
          {profiles.map((p) => (
            <tr key={p.operator_id}>
              <Td>{p.operator_name}<div className="text-xs text-text-tertiary capitalize">{p.operator_status}</div></Td>
              <Td>
                {p.has_bank_details ? (
                  <>
                    {p.account_holder}
                    <div className="font-mono text-xs text-text-secondary">{p.bank_name} · {p.account_masked} · {p.ifsc_masked}</div>
                  </>
                ) : <span className="text-text-tertiary">no bank details</span>}
              </Td>
              <Td>
                <Badge status={p.verification_status} />
                {p.verified_at && <div className="mt-1 text-xs text-text-tertiary">{fmtDateTime(p.verified_at)}</div>}
                {p.verification_note && <div className="mt-1 max-w-xs text-xs text-text-secondary">{p.verification_note}</div>}
              </Td>
              <Td>
                {p.block_reason ? <span className="text-xs text-warning">{BLOCK[p.block_reason] ?? p.block_reason}</span> : <Badge status="active" />}
                {p.payout_hold && p.restriction_reason && <div className="mt-1 max-w-xs text-xs text-text-secondary">{p.restriction_reason}</div>}
              </Td>
              <Td>
                <div className="flex flex-col gap-2">
                  <form action={setProfileStatus} className="flex gap-1">
                    <input type="hidden" name="operator_id" value={p.operator_id} />
                    <input type="hidden" name="status" value="verified" />
                    <ConfirmButton variant="outline" className="px-2 py-1 text-xs" disabled={!p.has_bank_details}
                      message={`Mark ${p.operator_name}'s bank details as verified? Check them against the operator's bank proof first.`}>
                      {p.verification_status === "verified" ? "Re-verify" : "Verify"}
                    </ConfirmButton>
                  </form>
                  <form action={setProfileStatus} className="flex gap-1">
                    <input type="hidden" name="operator_id" value={p.operator_id} />
                    <input type="hidden" name="status" value="failed" />
                    <input name="note" required placeholder="Why verification failed" className={`${inputClass} w-40`} />
                    <ConfirmButton variant="outline" className="px-2 py-1 text-xs" message="Mark verification as failed? The operator will be asked to correct their details.">Fail</ConfirmButton>
                  </form>
                  <form action={setPayoutHold} className="flex gap-1">
                    <input type="hidden" name="operator_id" value={p.operator_id} />
                    <input type="hidden" name="hold" value={p.payout_hold ? "false" : "true"} />
                    {!p.payout_hold && <input name="reason" required placeholder="Hold reason" className={`${inputClass} w-40`} />}
                    <ConfirmButton variant={p.payout_hold ? "outline" : "destructive"} className="px-2 py-1 text-xs" message={p.payout_hold ? "Remove the payout hold?" : "Hold all payouts for this operator?"}>
                      {p.payout_hold ? "Remove hold" : "Hold payouts"}
                    </ConfirmButton>
                  </form>
                </div>
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!profiles.length && <EmptyState message="No operators." />}
    </div>
  );
}
