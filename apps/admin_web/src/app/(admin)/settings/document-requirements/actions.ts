"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";

const PATH = "/settings/document-requirements";

function fail(message: string): never {
  redirect(`${PATH}?error=${encodeURIComponent(message)}`);
}

function parseCondition(raw: FormDataEntryValue | null): Record<string, unknown> {
  const text = typeof raw === "string" ? raw.trim() : "";
  if (text === "") return {};
  try {
    const value = JSON.parse(text);
    if (value === null || typeof value !== "object" || Array.isArray(value)) fail("Condition must be a JSON object, e.g. {\"gst_registered\": true}");
    return value as Record<string, unknown>;
  } catch {
    return fail("Condition is not valid JSON");
  }
}

function fieldsFrom(formData: FormData) {
  const label = String(formData.get("label") ?? "").trim();
  if (!label) fail("A label is required");
  const sort = Number(formData.get("sort_order") ?? 100);
  return {
    label,
    required: formData.get("required") === "on",
    active: formData.get("active") === "on",
    has_expiry: formData.get("has_expiry") === "on",
    sort_order: Number.isFinite(sort) ? Math.trunc(sort) : 100,
    condition: parseCondition(formData.get("condition")),
  };
}

/** Requirements drive what operators must upload and what "complete" means; changes apply to the next submission/approval check. */
export async function updateRequirement(id: string, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.from("document_requirements").update(fieldsFrom(formData)).eq("id", id);
  if (error) fail(error.message);
  revalidatePath(PATH);
}

export async function createRequirement(formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const scope = String(formData.get("scope") ?? "");
  const docType = String(formData.get("doc_type") ?? "").trim().toLowerCase();
  if (!["operator", "bus"].includes(scope)) fail("Choose a scope");
  if (!/^[a-z][a-z0-9_]{1,40}$/.test(docType)) fail("Document type must be lowercase letters, digits and underscores");

  const { error } = await supabase.from("document_requirements").insert({
    scope,
    doc_type: docType,
    step: scope === "bus" ? "bus" : String(formData.get("step") ?? "kyc"),
    ...fieldsFrom(formData),
  });
  if (error) fail(error.message);
  revalidatePath(PATH);
}
