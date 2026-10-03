"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";

function reasonFrom(formData: FormData): string | null {
  const value = formData.get("reason");
  const reason = typeof value === "string" ? value.trim() : "";
  return reason === "" ? null : reason;
}

/**
 * Approve or reject a pending route revision. admin_review_route_revision does everything in one
 * transaction: it re-validates the revision, activates it (live route + service + bus reference),
 * supersedes the previous revision, flags affected bookings and notifies the operator. A rejection
 * needs a reason and leaves the live route untouched.
 */
export async function reviewRouteRevision(revisionId: string, action: "approve" | "reject", formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const reason = reasonFrom(formData);
  if (action === "reject" && !reason) {
    redirect(`/route-approvals/${revisionId}?error=${encodeURIComponent("A reason is required to reject a route change")}`);
  }
  const { error } = await supabase.rpc("admin_review_route_revision", {
    p_revision_id: revisionId,
    p_action: action,
    p_reason: reason,
  });
  if (error) {
    redirect(`/route-approvals/${revisionId}?error=${encodeURIComponent(error.message)}`);
  }
  revalidatePath("/route-approvals");
  revalidatePath(`/route-approvals/${revisionId}`);
  redirect(`/route-approvals/${revisionId}?notice=${action === "approve" ? "approved" : "rejected"}`);
}
