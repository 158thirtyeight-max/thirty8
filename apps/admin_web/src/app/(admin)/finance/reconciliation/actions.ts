"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";
import { cleanError, fail, ok, text } from "../_util";

const HERE = "/finance/reconciliation";

export async function runReconciliation() {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("admin_run_reconciliation");
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  const d = data as { found?: number };
  ok(HERE, `Reconciliation finished: ${d.found ?? 0} finding(s). Nothing was changed to make records match.`);
}

/** An exception is closed only by a person, with a note. The records behind it are never edited. */
export async function resolveException(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const note = text(formData, "note");
  if (!note) fail(HERE, "A resolution note is required.");
  const { error } = await supabase.rpc("admin_resolve_exception", {
    p_exception_id: text(formData, "id") ?? "",
    p_status: text(formData, "status") ?? "resolved",
    p_note: note,
  });
  if (error) fail(HERE, cleanError(error.message));
  revalidatePath(HERE);
  ok(HERE, "Exception closed.");
}
