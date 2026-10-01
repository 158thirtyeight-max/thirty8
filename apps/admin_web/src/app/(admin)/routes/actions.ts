"use server";

import { revalidatePath } from "next/cache";
import { requirePlatformAdmin } from "@/lib/auth";

export type RouteStopInput = {
  name: string;
  city_id: string | null;
  is_boarding: boolean;
  is_dropping: boolean;
  arrival_offset_min: number | null;
  departure_offset_min: number | null;
};

export type RouteInput = {
  id: string | null;
  name: string;
  source_city_id: string;
  destination_city_id: string;
  distance_km: number | null;
  est_duration_min: number | null;
  is_active: boolean;
  stops: RouteStopInput[];
};

/** Saves the route and its stops atomically through admin_save_route_template. Returns the route id, or an error message. */
export async function saveRoute(input: RouteInput): Promise<{ id?: string; error?: string }> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("admin_save_route_template", {
    p_id: input.id,
    p_name: input.name,
    p_source_city_id: input.source_city_id || null,
    p_destination_city_id: input.destination_city_id || null,
    p_distance_km: input.distance_km,
    p_est_duration_min: input.est_duration_min,
    p_is_active: input.is_active,
    p_stops: input.stops,
  });
  if (error) return { error: error.message };
  revalidatePath("/routes");
  return { id: data as string };
}

export async function deleteRoute(id: string): Promise<{ error?: string }> {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.from("route_templates").delete().eq("id", id);
  if (error) return { error: error.message };
  revalidatePath("/routes");
  return {};
}
