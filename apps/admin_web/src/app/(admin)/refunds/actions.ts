"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { rupeesToCents } from "@/lib/money";
import { cleanError, fail, ok, text } from "../finance/_util";

// Refund lifecycle: requested -> approved -> submitted_to_provider -> processed | failed (+ rejected).
// Policies, calculations, overrides, authorization and audit are enforced INSIDE the database RPCs (full admin
// required); these actions are thin callers. Operators and customers have no path to any of them.

const HERE = "/refunds";

/** Approve: the database calculates the refund from the booking's policy snapshot (or the policy chosen here). */
export async function approveRefundForm(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_approve_refund", {
    p_refund_id: text(formData, "refund_id") ?? "",
    p_policy_id: text(formData, "policy_id") ?? undefined,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, "Refund approved. It is not paid until you execute it.");
}

export async function overrideRefundForm(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const cents = rupeesToCents(text(formData, "amount"));
  if (cents === null || cents <= 0) fail(HERE, "Enter the authorized refund amount in rupees.");
  const { error } = await supabase.rpc("admin_override_refund", {
    p_refund_id: text(formData, "refund_id") ?? "",
    p_final_cents: cents,
    p_reason: text(formData, "reason") ?? "",
    p_policy_id: text(formData, "policy_id") ?? undefined,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, "Override recorded with your reason. Approve the refund to authorize it.");
}

export async function rejectRefund(refundId: string, reason: string) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_reject_refund", { p_refund_id: refundId, p_reason: reason });
  if (error) throw new Error(cleanError(error.message));
  revalidatePath(HERE);
}

export async function retryRefund(refundId: string) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_retry_refund", { p_refund_id: refundId });
  if (error) throw new Error(cleanError(error.message));
  revalidatePath(HERE);
}

/**
 * Executes an APPROVED refund through the `refund` Edge Function with this admin's own session. The function claims the
 * refund under a row lock, asks Razorpay whether it already exists, and completes it only when Razorpay reports it processed.
 */
export async function executeRefund(refundId: string) {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.functions.invoke("refund", { body: { refund_id: refundId } });
  if (error) {
    let message = error.message;
    try {
      const ctx = (error as { context?: Response }).context;
      if (ctx) message = ((await ctx.json()) as { error?: string }).error ?? message;
    } catch {}
    throw new Error(message);
  }
  revalidatePath(HERE);
  return data;
}
