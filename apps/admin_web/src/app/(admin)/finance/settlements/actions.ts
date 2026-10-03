"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";
import { cleanError, fail, ok, text } from "../_util";

// Every rule (full admin, verified payout profile, maker-checker, state checks, audit) lives in the database RPCs.
// These actions only call them and report the outcome.

function back(formData: FormData, fallback = "/finance/settlements"): string {
  const r = text(formData, "return");
  return r && r.startsWith("/finance/settlements") ? r : fallback;
}

export async function buildSettlements(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("admin_build_weekly_settlement", {
    p_period_end: text(formData, "period_end") ?? undefined,
    p_operator_id: text(formData, "operator_id") ?? undefined,
  });
  if (error) fail("/finance/settlements", cleanError(error.message));
  revalidatePath("/finance/settlements");
  const built = (data as { built?: number } | null)?.built ?? 0;
  const reasons = ((data as { operators?: { result: string; reason?: string }[] } | null)?.operators ?? [])
    .filter((o) => o.result !== "built")
    .map((o) => o.reason ?? o.result);
  ok("/finance/settlements", `${built} draft batch(es) created.${reasons.length ? ` Skipped: ${[...new Set(reasons)].join(", ")}.` : ""}`);
}

export async function approveSettlement(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const id = text(formData, "id") ?? "";
  const { error } = await supabase.rpc("admin_approve_settlement", { p_settlement_id: id });
  if (error) fail(back(formData), cleanError(error.message));
  revalidatePath("/finance/settlements");
  ok(back(formData), "Batch approved. The beneficiary bank details are now frozen for this batch.");
}

export async function holdSettlement(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const reason = text(formData, "reason");
  if (!reason) fail(back(formData), "A reason is required to hold a settlement");
  const { error } = await supabase.rpc("admin_hold_settlement", { p_settlement_id: text(formData, "id") ?? "", p_reason: reason });
  if (error) fail(back(formData), cleanError(error.message));
  revalidatePath("/finance/settlements");
  ok(back(formData), "Batch put on hold.");
}

export async function releaseSettlementHold(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_release_settlement_hold", { p_settlement_id: text(formData, "id") ?? "" });
  if (error) fail(back(formData), cleanError(error.message));
  revalidatePath("/finance/settlements");
  ok(back(formData), "Hold released. The batch is a draft again and must be approved again.");
}

export async function cancelSettlement(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const reason = text(formData, "reason");
  if (!reason) fail(back(formData), "A reason is required to cancel a batch");
  const { error } = await supabase.rpc("admin_cancel_settlement", { p_settlement_id: text(formData, "id") ?? "", p_reason: reason });
  if (error) fail(back(formData), cleanError(error.message));
  revalidatePath("/finance/settlements");
  redirect(`/finance/settlements?ok=${encodeURIComponent("Batch cancelled. Its earnings are eligible again.")}`);
}

export async function settleZeroBatch(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const reason = text(formData, "reason");
  if (!reason) fail(back(formData), "A reason is required");
  const { error } = await supabase.rpc("admin_settle_zero_batch", { p_settlement_id: text(formData, "id") ?? "", p_reason: reason });
  if (error) fail(back(formData), cleanError(error.message));
  revalidatePath("/finance/settlements");
  ok(back(formData), "Zero-payment batch settled (recovery netting recorded).");
}

/** Builds the immutable SBI payment file for the ticked approved batches, then sends the browser to download it. */
export async function exportSettlements(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const ids = formData.getAll("ids").filter((v): v is string => typeof v === "string" && v !== "");
  if (!ids.length) fail("/finance/settlements", "Tick at least one approved batch to export.");
  const { data, error } = await supabase.rpc("admin_export_settlement_file", { p_settlement_ids: ids });
  if (error) fail("/finance/settlements", cleanError(error.message));
  revalidatePath("/finance/settlements");
  redirect(`/finance/settlements/export/${(data as { export_id: string }).export_id}`);
}
