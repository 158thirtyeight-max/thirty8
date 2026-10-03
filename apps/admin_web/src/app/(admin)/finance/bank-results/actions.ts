"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";
import { parseBankResult } from "@/lib/bank-result";
import { cleanError, fail, text } from "../_util";

const MAX_BYTES = 2 * 1024 * 1024;

/** Step 1: parse the bank's result file and validate every row against our exported batches. Changes nothing. */
export async function previewBankResult(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const file = formData.get("file");
  if (!(file instanceof File) || file.size === 0) fail("/finance/bank-results", "Choose the bank result CSV file.");
  if ((file as File).size > MAX_BYTES) fail("/finance/bank-results", "The file is larger than 2 MB.");
  const content = await (file as File).text();
  const parsed = parseBankResult(content);
  if (parsed.error) fail("/finance/bank-results", parsed.error);

  const { data, error } = await supabase.rpc("admin_preview_bank_result", {
    p_file_name: (file as File).name,
    p_rows: parsed.rows,
    p_file_text: content,
  });
  if (error) fail("/finance/bank-results", cleanError(error.message));
  revalidatePath("/finance/bank-results");
  const d = data as { import_id: string; already_imported: boolean };
  const note = d.already_imported ? "This exact file was already imported; nothing changes." : "Preview ready. Nothing has been applied yet.";
  redirect(`/finance/bank-results/${d.import_id}?ok=${encodeURIComponent(note)}`);
}

/** Step 2: apply the matched rows. Maker-checker, UTR uniqueness and idempotency are enforced by the database. */
export async function confirmBankResult(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const id = text(formData, "id") ?? "";
  const { data, error } = await supabase.rpc("admin_confirm_bank_result", { p_import_id: id });
  if (error) fail(`/finance/bank-results/${id}`, cleanError(error.message));
  revalidatePath("/finance/bank-results");
  revalidatePath("/finance/settlements");
  const d = data as { paid?: number; failed?: number; exceptions?: number; already_confirmed?: boolean };
  const msg = d.already_confirmed
    ? "Already confirmed earlier; nothing was applied twice."
    : `Applied: ${d.paid ?? 0} batch(es) marked paid, ${d.failed ?? 0} marked failed, ${d.exceptions ?? 0} row(s) sent to the exception queue.`;
  redirect(`/finance/bank-results/${id}?ok=${encodeURIComponent(msg)}`);
}
