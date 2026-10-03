"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { rupeesToCents } from "@/lib/money";
import { cleanError, fail, ok, text } from "../_util";

const HERE = "/finance/recoveries";

/** Recording a payment received from the operator, or writing the debt off. Operators cannot do either. Full admin enforced in the database. */
export async function updateRecovery(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const action = text(formData, "action") ?? "";
  let amount: number | undefined;
  if (action === "record_recovery") {
    const cents = rupeesToCents(text(formData, "amount"));
    if (cents === null || cents <= 0) fail(HERE, "Enter the amount received in rupees.");
    amount = cents as number;
  }
  const { error } = await supabase.rpc("admin_update_recovery", {
    p_recovery_id: text(formData, "id") ?? "",
    p_action: action,
    p_amount_cents: amount,
    p_reason: text(formData, "reason") ?? undefined,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, action === "write_off" ? "Recovery written off." : "Recovery payment recorded.");
}
