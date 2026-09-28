"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";

export async function setOperatorStatus(operatorId: string, status: "approved" | "rejected" | "suspended" | "pending") {
  const { supabase, user } = await requirePlatformAdmin();

  const patch: Record<string, unknown> = { status };
  if (status === "approved") {
    patch.approved_by = user.id;
    patch.approved_at = new Date().toISOString();
  }

  const { error } = await supabase.from("operators").update(patch).eq("id", operatorId);
  if (error) throw new Error(error.message);

  revalidatePath("/operators");
  revalidatePath(`/operators/${operatorId}`);
}

export async function setInsuranceStatus(insuranceId: string, operatorId: string, status: "verified" | "rejected", rejectionReason?: string) {
  const { supabase, user } = await requirePlatformAdmin();

  const { error } = await supabase
    .from("operator_insurance")
    .update({
      status,
      verified_by: user.id,
      verified_at: new Date().toISOString(),
      rejection_reason: status === "rejected" ? rejectionReason ?? null : null,
    })
    .eq("id", insuranceId);
  if (error) throw new Error(error.message);

  revalidatePath(`/operators/${operatorId}`);
}
