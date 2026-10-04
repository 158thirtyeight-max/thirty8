"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";

function int(value: FormDataEntryValue | null, label: string): number {
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0) throw new Error(`${label} must be a whole number`);
  return n;
}

/** Global default + bounds + booking rules. RLS (platform admin only) is the real gate. */
export async function saveGlobalSettings(formData: FormData) {
  const { supabase, user } = await requirePlatformAdmin();

  const { error } = await supabase
    .from("scheduling_settings")
    .update({
      default_advance_days: int(formData.get("default_advance_days"), "Default advance days"),
      min_advance_days: int(formData.get("min_advance_days"), "Minimum advance days"),
      max_advance_days: int(formData.get("max_advance_days"), "Maximum advance days"),
      allow_operator_overrides: formData.get("allow_operator_overrides") === "on",
      default_booking_close_minutes: int(formData.get("default_booking_close_minutes"), "Default booking close"),
      max_booking_close_minutes: int(formData.get("max_booking_close_minutes"), "Max booking close"),
      default_boarding_cutoff_minutes: int(formData.get("default_boarding_cutoff_minutes"), "Default boarding cut-off"),
      max_boarding_cutoff_minutes: int(formData.get("max_boarding_cutoff_minutes"), "Max boarding cut-off"),
      allow_operator_booking_rules: formData.get("allow_operator_booking_rules") === "on",
      updated_by: user.id,
      updated_at: new Date().toISOString(),
    })
    .eq("id", true);
  if (error) throw new Error(error.message);

  revalidatePath("/scheduling/booking-windows");
}

/** Create/replace a route-specific window. Generation for the route's services runs inside the database trigger. */
export async function saveRouteWindow(routeId: string, advanceDays: number, enabled: boolean) {
  const { supabase, user } = await requirePlatformAdmin();
  if (!Number.isInteger(advanceDays) || advanceDays < 1) throw new Error("Advance booking must be at least 1 day");

  const { error } = await supabase.from("route_booking_windows").upsert(
    { route_id: routeId, advance_days: advanceDays, override_enabled: enabled, updated_by: user.id },
    { onConflict: "route_id" },
  );
  if (error) throw new Error(error.message);

  revalidatePath("/scheduling/booking-windows");
}

/** Remove the route override so the route falls back to the global default. */
export async function clearRouteWindow(routeId: string) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.from("route_booking_windows").delete().eq("route_id", routeId);
  if (error) throw new Error(error.message);
  revalidatePath("/scheduling/booking-windows");
}

export async function decideCancellation(tripId: string, approve: boolean, note: string) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_decide_trip_cancellation", {
    p_trip_id: tripId,
    p_approve: approve,
    p_note: note || null,
  });
  if (error) throw new Error(error.message);
  revalidatePath("/scheduling/departures");
  revalidatePath("/refunds");
}

export async function runGenerationNow() {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_run_schedule_generation");
  if (error) throw new Error(error.message);
  revalidatePath("/scheduling/departures");
}
