"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requirePlatformAdmin } from "@/lib/auth";

/* eslint-disable @typescript-eslint/no-explicit-any */

/**
 * Every route write goes through the revision RPCs (start / save / generate_reverse / publish / copy):
 * the admin panel never writes the live route tables or the revision tables directly.
 */

export type Validation = { valid: boolean; errors: { direction?: string; message: string }[] };

/** Starts (or resumes) an admin draft revision for a bus and opens the builder. */
export async function startRevision(busId: string) {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("start_route_revision", { p_bus_id: busId, p_base_revision_id: null });
  if (error) redirect(`/bus-routes/${busId}?error=${encodeURIComponent(error.message)}`);
  redirect(`/bus-routes/edit/${data as string}`);
}

export async function loadRevision(revisionId: string): Promise<{ revision?: any; error?: string }> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase
    .from("route_revisions")
    .select("*, route_revision_journeys(*, route_revision_stops(*, location:locations(name)))")
    .eq("id", revisionId)
    .single();
  if (error) return { error: error.message };
  return { revision: data };
}

export async function saveRevision(revisionId: string, payload: any): Promise<{ validation?: Validation; error?: string }> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("save_route_revision", { p_revision_id: revisionId, p_payload: payload });
  if (error) return { error: error.message };
  return { validation: data as Validation };
}

/** Builds the return journey from the (already saved) outbound one on the server and returns the result. */
export async function generateReverse(revisionId: string): Promise<{ validation?: Validation; revision?: any; error?: string }> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("generate_reverse_route", { p_revision_id: revisionId });
  if (error) return { error: error.message };
  const loaded = await loadRevision(revisionId);
  return { validation: data as Validation, revision: loaded.revision, error: loaded.error };
}

export async function getDiff(revisionId: string): Promise<{ diff?: any; error?: string }> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("get_route_revision_diff", { p_revision_id: revisionId });
  if (error) return { error: error.message };
  return { diff: data };
}

export async function publishRevision(revisionId: string, reason: string): Promise<{ ok?: boolean; errors?: { message: string }[]; error?: string }> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("admin_publish_route_revision", { p_revision_id: revisionId, p_reason: reason });
  if (error) return { error: error.message };
  const res = data as any;
  if (!res?.ok) return { ok: false, errors: res?.errors ?? [] };
  revalidatePath("/bus-routes");
  revalidatePath("/route-history");
  return { ok: true };
}

export async function discardDraft(revisionId: string, busId: string) {
  const { supabase } = await requirePlatformAdmin();
  const { error } = await supabase.rpc("withdraw_route_revision", { p_revision_id: revisionId });
  revalidatePath(`/bus-routes/${busId}`);
  revalidatePath("/bus-routes");
  redirect(`/bus-routes/${busId}${error ? `?error=${encodeURIComponent(error.message)}` : ""}`);
}

/** Copies a bus's route into a new independent draft on another bus. Returns needs_confirmation when the destination already has a route. */
export async function copyRoute(sourceBusId: string, destBusId: string, replace: boolean): Promise<{
  revisionId?: string;
  needsConfirmation?: { hasRoute: boolean; hasDraft: boolean; routeName: string | null };
  error?: string;
}> {
  const { supabase } = await requirePlatformAdmin();
  const { data, error } = await supabase.rpc("copy_route_to_bus", { p_source_bus_id: sourceBusId, p_dest_bus_id: destBusId, p_replace: replace });
  if (error) return { error: error.message };
  const res = data as any;
  if (res?.needs_confirmation) {
    return { needsConfirmation: { hasRoute: !!res.destination_has_route, hasDraft: !!res.destination_has_draft, routeName: res.destination_route_name ?? null } };
  }
  revalidatePath("/bus-routes");
  return { revisionId: res.revision_id as string };
}
