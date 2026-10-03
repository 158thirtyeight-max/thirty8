"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { pctToBps } from "@/lib/money";
import { cleanError, fail, ok, text } from "../_util";

const HERE = "/finance/refund-policies";

function numOrNull(v: string | null): number | null {
  if (v === null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : NaN;
}

/**
 * Create or edit a cancellation policy. Percentages are typed as percent and stored as basis points; the database
 * validates the ranges, rejects overlapping policies, versions every change and writes the audit log.
 * Nothing about refund percentages is hardcoded anywhere: this screen is where they live.
 */
export async function savePolicy(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const id = text(formData, "id");
  const back = id ? `${HERE}?edit=${id}` : HERE;
  const refundBps = pctToBps(text(formData, "refund_pct"));
  const shareBps = pctToBps(text(formData, "operator_share_pct"));
  if (refundBps === null) fail(back, "Refund percentage must be between 0 and 100.");
  if (shareBps === null) fail(back, "The operator's share of the deduction must be between 0 and 100 percent.");
  const minH = numOrNull(text(formData, "min_hours"));
  const maxH = numOrNull(text(formData, "max_hours"));
  if (Number.isNaN(minH) || Number.isNaN(maxH)) fail(back, "Hours before departure must be numbers.");

  const { error } = await supabase.rpc("admin_save_refund_policy", {
    p_name: text(formData, "name") ?? "",
    p_category: (text(formData, "category") ?? "").toLowerCase(),
    p_refund_bps: refundBps,
    p_deduction_operator_share_bps: shareBps,
    p_min_hours: minH ?? undefined,
    p_max_hours: maxH ?? undefined,
    p_effective_from: text(formData, "effective_from") ?? undefined,
    p_effective_until: text(formData, "effective_until") ?? undefined,
    p_description: text(formData, "description") ?? undefined,
    p_allow_fixed_override: formData.get("allow_fixed_override") === "on",
    p_status: text(formData, "status") ?? "active",
    p_policy_id: id ?? undefined,
  });
  if (error) fail(back, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, id ? "Policy updated as a new version. Existing bookings keep the policy they were booked under." : "Policy created.");
}

export async function setPolicyStatus(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_set_refund_policy_status", {
    p_policy_id: text(formData, "id") ?? "",
    p_status: text(formData, "status") ?? "",
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, "Policy status changed.");
}
