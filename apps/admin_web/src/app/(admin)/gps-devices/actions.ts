"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";

function text(formData: FormData, key: string): string | null {
  const v = formData.get(key);
  const s = typeof v === "string" ? v.trim() : "";
  return s === "" ? null : s;
}

function back(message?: string): never {
  revalidatePath("/gps-devices");
  redirect(message ? `/gps-devices?error=${encodeURIComponent(message)}` : "/gps-devices");
}

/**
 * Every change goes through an admin_* RPC (platform-admin checked in the database, audited).
 * provider_config_ref is the NAME of a server-side secret — credentials are never typed into this page.
 */
export async function saveDevice(deviceId: string | null, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const data: Record<string, string | null> = {
    name: text(formData, "name"),
    provider: text(formData, "provider"),
    integration_type: text(formData, "integration_type"),
    device_identifier: text(formData, "device_identifier"),
    imei: text(formData, "imei"),
    serial_no: text(formData, "serial_no"),
    sim_ref: text(formData, "sim_ref"),
    installed_on: text(formData, "installed_on"),
    notes: text(formData, "notes"),
    provider_config_ref: text(formData, "provider_config_ref"),
  };
  const { error } = await supabase.rpc("admin_save_gps_device", { p_device_id: deviceId, p_data: data });
  if (error) back(error.message);
  back();
}

export async function setDeviceState(deviceId: string, state: "registered" | "active" | "inactive" | "retired") {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_set_gps_device_state", { p_device_id: deviceId, p_state: state });
  if (error) back(error.message);
  back();
}

export async function assignDevice(deviceId: string, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const busId = text(formData, "bus_id");
  if (!busId) back("Choose a bus to assign the device to");
  const { error } = await supabase.rpc("admin_assign_gps_device", { p_device_id: deviceId, p_bus_id: busId });
  if (error) back(error.message);
  back();
}

export async function unassignDevice(deviceId: string) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_unassign_gps_device", { p_device_id: deviceId });
  if (error) back(error.message);
  back();
}

export async function setDriverFallback(busId: string, enabled: boolean) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("admin_set_bus_driver_fallback", { p_bus_id: busId, p_enabled: enabled });
  if (error) back(error.message);
  back();
}
