"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";

type BusAction = "start_review" | "approve" | "request_changes" | "reject" | "suspend" | "reinstate";

function reasonFrom(formData: FormData): string | null {
  const value = formData.get("reason");
  const reason = typeof value === "string" ? value.trim() : "";
  return reason === "" ? null : reason;
}

function backWithError(busId: string, message: string): never {
  redirect(`/buses/${busId}?error=${encodeURIComponent(message)}`);
}

function refresh(busId: string) {
  revalidatePath("/buses");
  revalidatePath(`/buses/${busId}`);
}

/**
 * Every bus state change goes through admin_review_bus, which validates the
 * transition, requires a reason where needed, enforces the approval checks
 * (documents verified, layout/route/fares/schedule valid) and writes the audit trail.
 */
export async function reviewBus(busId: string, action: BusAction, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_review_bus", {
    p_bus_id: busId,
    p_action: action,
    p_reason: reasonFrom(formData),
  });
  if (error) backWithError(busId, error.message);
  refresh(busId);
}

export async function reviewBusDocument(docId: string, busId: string, action: "verify" | "reject", formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_review_bus_document", {
    p_doc_id: docId,
    p_action: action,
    p_reason: reasonFrom(formData),
  });
  if (error) backWithError(busId, error.message);
  refresh(busId);
}
