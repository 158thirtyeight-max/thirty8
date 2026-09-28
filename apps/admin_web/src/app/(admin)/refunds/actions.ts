"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";

/**
 * Invokes the `refund` Edge Function with this admin's own session — the
 * function re-checks am_i_platform_admin() server-side, so there is no
 * client-trusted authorization happening here, only a convenience gate.
 */
export async function processRefund(refundId: string) {
  const { supabase } = await requirePlatformAdmin();

  const { error } = await supabase.functions.invoke("refund", {
    body: { refund_id: refundId },
  });
  if (error) throw new Error(error.message);

  revalidatePath("/refunds");
}
