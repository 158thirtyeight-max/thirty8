"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";

const PATH = "/locations";

type Tab = "main" | "points";

function back(tab: Tab, params: Record<string, string>): never {
  const q = new URLSearchParams({ tab, ...params });
  redirect(`${PATH}?${q.toString()}`);
}

function refresh() {
  revalidatePath(PATH);
  revalidatePath("/routes");
}

function str(formData: FormData, key: string): string {
  const v = formData.get(key);
  return typeof v === "string" ? v.trim() : "";
}

function intOr(formData: FormData, key: string, fallback: number): number {
  const n = Number(str(formData, key));
  return Number.isFinite(n) && str(formData, key) !== "" ? Math.trunc(n) : fallback;
}

function coord(formData: FormData, key: string, tab: Tab, min: number, max: number): number | null {
  const raw = str(formData, key);
  if (raw === "") return null;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < min || n > max) back(tab, { error: `${key === "latitude" ? "Latitude" : "Longitude"} must be a number between ${min} and ${max}` });
  return n;
}

/** Friendlier messages for the constraints an admin can realistically hit. */
function explain(message: string): string {
  if (message.includes("cities_slug_uniq")) return "A location with this name already exists.";
  if (message.includes("pickup_drop_points_name_uniq")) return "This main location already has a point with that name.";
  if (message.includes("pickup_drop_points_coords_pair")) return "Enter both latitude and longitude, or leave both empty.";
  return message;
}

/** Main locations are written through the main_locations view (admin-only by RLS). Never deleted — only deactivated. */
export async function saveLocation(id: string | null, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const name = str(formData, "name").toUpperCase().replace(/\s+/g, " ");
  if (!name) back("main", { error: "A location name is required" });

  const order = intOr(formData, "display_order", NaN);
  if (id) {
    const patch: Record<string, unknown> = { name };
    if (Number.isFinite(order)) patch.display_order = order;
    const { error } = await supabase.from("main_locations").update(patch).eq("id", id);
    if (error) back("main", { error: explain(error.message) });
  } else {
    const row: Record<string, unknown> = { name, state: "Andaman and Nicobar Islands" };
    if (Number.isFinite(order)) row.display_order = order;
    const { error } = await supabase.from("main_locations").insert(row);
    if (error) back("main", { error: explain(error.message) });
  }
  refresh();
  back("main", { notice: id ? "Location saved." : "Location added." });
}

export async function setLocationActive(id: string, active: boolean) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.from("main_locations").update({ is_active: active }).eq("id", id);
  if (error) back("main", { error: explain(error.message) });
  refresh();
  back("main", { notice: active ? "Location enabled." : "Location disabled. Existing routes and bookings are unchanged." });
}

export async function savePoint(id: string | null, formData: FormData) {
  const { supabase } = await requirePlatformAdmin();
  const name = str(formData, "name");
  const locationId = str(formData, "main_location_id");
  if (!name) back("points", { error: "A point name is required" });
  if (!locationId) back("points", { error: "Choose the parent main location" });

  const row = {
    main_location_id: locationId,
    name,
    landmark: str(formData, "landmark") || null,
    address: str(formData, "address") || null,
    latitude: coord(formData, "latitude", "points", -90, 90),
    longitude: coord(formData, "longitude", "points", -180, 180),
    is_pickup_allowed: formData.get("is_pickup_allowed") === "on",
    is_drop_allowed: formData.get("is_drop_allowed") === "on",
    is_active: id ? formData.get("is_active") === "on" : true,
    display_order: intOr(formData, "display_order", 0),
  };
  if (!row.is_pickup_allowed && !row.is_drop_allowed && row.is_active) {
    back("points", { error: "Enable pickup, drop or both — or disable the whole point" });
  }

  const { error } = id
    ? await supabase.from("pickup_drop_points").update(row).eq("id", id)
    : await supabase.from("pickup_drop_points").insert(row);
  if (error) back("points", { error: explain(error.message) });
  refresh();
  back("points", { notice: id ? "Point saved." : "Point added.", loc: locationId });
}

export async function setPointActive(id: string, active: boolean) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.from("pickup_drop_points").update({ is_active: active }).eq("id", id);
  if (error) back("points", { error: explain(error.message) });
  refresh();
  back("points", { notice: active ? "Point enabled." : "Point disabled. Buses already using it keep their stop." });
}
