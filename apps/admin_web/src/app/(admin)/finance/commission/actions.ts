"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { pctToBps } from "@/lib/money";
import { cleanError, fail, ok, text } from "../_util";

const HERE = "/finance/commission";

/** A new rate applies to tickets confirmed from now on; the rate on existing tickets is frozen. Full admin is enforced in the database. */
export async function setCommission(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const bps = pctToBps(text(formData, "percent"));
  if (bps === null) fail(HERE, "Enter a commission between 0 and 100 percent.");
  const { error } = await supabase.rpc("admin_set_commission", {
    p_operator_id: text(formData, "operator_id") ?? undefined,
    p_rate_bps: bps,
    p_effective_from: text(formData, "effective_from") ?? undefined,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, "Commission saved. Existing tickets keep the rate they were created with.");
}

export async function deactivateCommission(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_deactivate_commission", { p_config_id: text(formData, "id") ?? "" });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, "Commission setting deactivated.");
}
