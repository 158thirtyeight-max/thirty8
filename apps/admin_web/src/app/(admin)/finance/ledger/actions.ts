"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { rupeesToCents } from "@/lib/money";
import { cleanError, fail, ok, text } from "../_util";

const HERE = "/finance/ledger";

/** Books money Razorpay settled to the bank, from Razorpay's settlement report. The same Razorpay settlement id is booked once. */
export async function recordProviderSettlement(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const cents = rupeesToCents(text(formData, "amount"));
  if (cents === null || cents <= 0) fail(HERE, "Enter the settled amount in rupees, as shown in the Razorpay settlement report.");
  const { error } = await supabase.rpc("admin_record_provider_settlement", {
    p_provider_reference: text(formData, "reference") ?? "",
    p_amount_cents: cents,
    p_settled_on: text(formData, "settled_on") ?? undefined,
    p_note: text(formData, "note") ?? undefined,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, "Razorpay settlement recorded: money moved from Razorpay clearing to the settlement bank.");
}
