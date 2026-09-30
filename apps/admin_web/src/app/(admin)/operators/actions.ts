"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";

type OperatorAction = "start_review" | "approve" | "reject" | "request_changes" | "suspend" | "reinstate";

function reasonFrom(formData: FormData): string | null {
  const value = formData.get("reason");
  const reason = typeof value === "string" ? value.trim() : "";
  return reason === "" ? null : reason;
}

/** Sends the admin back to the operator page with the failure shown instead of a crash page. */
function backWithError(operatorId: string, message: string): never {
  redirect(`/operators/${operatorId}?error=${encodeURIComponent(message)}`);
}

function refresh(operatorId: string) {
  revalidatePath("/operators");
  revalidatePath(`/operators/${operatorId}`);
}

/**
 * All operator state changes go through the admin_review_operator RPC, which
 * validates the transition, requires a reason where needed, stamps who/when,
 * and writes the audit trail.
 */
export async function reviewOperator(operatorId: string, action: OperatorAction, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_review_operator", {
    p_operator_id: operatorId,
    p_action: action,
    p_reason: reasonFrom(formData),
  });
  if (error) backWithError(operatorId, error.message);
  refresh(operatorId);
}

export async function reviewOperatorDocument(
  docId: string,
  operatorId: string,
  action: "verify" | "reject",
  formData: FormData,
) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_review_operator_document", {
    p_doc_id: docId,
    p_action: action,
    p_reason: reasonFrom(formData),
  });
  if (error) backWithError(operatorId, error.message);
  refresh(operatorId);
}

export async function reviewMandate(operatorId: string, action: "verify" | "reject", formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_review_mandate", {
    p_operator_id: operatorId,
    p_action: action,
    p_reason: reasonFrom(formData),
  });
  if (error) backWithError(operatorId, error.message);
  refresh(operatorId);
}

export async function setInsuranceStatus(
  insuranceId: string,
  operatorId: string,
  status: "verified" | "rejected",
  formData: FormData,
) {
  const { supabase, user } = await requirePlatformAdmin();
  const reason = reasonFrom(formData);
  if (status === "rejected" && !reason) backWithError(operatorId, "A reason is required to reject an insurance policy.");

  const { error } = await supabase
    .from("operator_insurance")
    .update({
      status,
      verified_by: user.id,
      verified_at: new Date().toISOString(),
      rejection_reason: status === "rejected" ? reason : null,
    })
    .eq("id", insuranceId);
  if (error) backWithError(operatorId, error.message);

  revalidatePath(`/operators/${operatorId}`);
}
