"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { cleanError, fail, ok, text } from "../_util";

export async function holdEarning(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const id = text(formData, "id") ?? "";
  const reason = text(formData, "reason");
  if (!reason) fail("/finance/earnings", "A reason is required to hold an earning");
  const { error } = await supabase.rpc("admin_hold_earning", { p_earning_id: id, p_hold: true, p_reason: reason });
  if (error) fail("/finance/earnings", cleanError(error.message));
  revalidatePath("/finance/earnings");
  ok("/finance/earnings", "Earning held. It will not enter a settlement until you release it.");
}

export async function releaseEarning(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const id = text(formData, "id") ?? "";
  const { error } = await supabase.rpc("admin_hold_earning", { p_earning_id: id, p_hold: false });
  if (error) fail("/finance/earnings", cleanError(error.message));
  revalidatePath("/finance/earnings");
  ok("/finance/earnings", "Hold released.");
}
