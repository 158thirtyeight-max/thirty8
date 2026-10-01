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

/** Copies a catalog route onto the bus (stops, timings, operating days) via admin_assign_route_to_bus. */
export async function assignRoute(busId: string, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const templateId = String(formData.get("template_id") ?? "");
  const time = String(formData.get("departure_time") ?? "");
  const days = formData.getAll("days").map(Number).filter((d) => d >= 1 && d <= 7);
  if (!templateId) backWithError(busId, "Choose a route to assign");
  if (!time) backWithError(busId, "Enter the departure time");
  if (days.length === 0) backWithError(busId, "Select at least one operating day");
  const { error } = await supabase.rpc("admin_assign_route_to_bus", {
    p_bus_id: busId,
    p_template_id: templateId,
    p_departure_time: time.length === 5 ? `${time}:00` : time,
    p_operating_days: days,
  });
  if (error) backWithError(busId, error.message);
  refresh(busId);
}
