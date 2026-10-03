"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { cleanError, fail, ok, text } from "../_util";

const HERE = "/finance/payout-profiles";

/** Verification is a deliberate admin decision (checked against the bank document); the database freezes the verified details. */
export async function setProfileStatus(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const status = text(formData, "status") ?? "";
  const { error } = await supabase.rpc("admin_set_payment_profile_status", {
    p_operator_id: text(formData, "operator_id") ?? "",
    p_status: status,
    p_note: text(formData, "note") ?? undefined,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, status === "verified" ? "Payout profile verified. Any later change to the bank details requires verification again." : "Payout profile updated.");
}

export async function setPayoutHold(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const hold = text(formData, "hold") === "true";
  const { error } = await supabase.rpc("admin_set_payout_hold", {
    p_operator_id: text(formData, "operator_id") ?? "",
    p_hold: hold,
    p_reason: text(formData, "reason") ?? undefined,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, hold ? "Payouts held for this operator." : "Payout hold removed.");
}
