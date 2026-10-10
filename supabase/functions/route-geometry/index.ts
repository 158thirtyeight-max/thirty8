import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callerClient, serviceRoleClient } from "../_shared/supabase.ts";
import { buildRouteUrl, parseRouteResponse } from "../_shared/osrm.ts";

// Builds (or reuses) the road-following geometry of one route.
//   * The caller must be staff of the route's operator or a platform admin (checked in
//     get_route_geometry_inputs, which runs with the caller's JWT).
//   * If the stored geometry still matches the route's current stops it is returned untouched and
//     OSRM is NOT called. OSRM is only asked when the stops changed (or `force` is set).
//   * Saving goes through save_route_geometry (service role), which refuses geometry built from
//     stops that changed in the meantime.
// OSRM_BASE_URL is a function secret. The public demo server is for light testing only; point this
// at your own OSRM instance (Andaman extract) in production.
Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { route_id, force } = await req.json();
    if (!route_id || typeof route_id !== "string") return jsonResponse({ error: "route_id is required" }, 400);

    const { data: inputs, error } = await callerClient(req).rpc("get_route_geometry_inputs", { p_route_id: route_id });
    if (error || !inputs) return jsonResponse({ error: error?.message ?? "Route not found" }, 403);

    if (inputs.is_current && !force) return jsonResponse({ status: "cached", route_id });

    const waypoints = inputs.waypoints as Array<{ latitude: number; longitude: number }>;
    if (!Array.isArray(waypoints) || waypoints.length < 2) {
      return jsonResponse({ status: "needs_coordinates", message: "At least two stops need map coordinates" }, 422);
    }

    const base = Deno.env.get("OSRM_BASE_URL") ?? "https://router.project-osrm.org";
    const res = await fetch(buildRouteUrl(base, waypoints), { signal: AbortSignal.timeout(20000) });
    if (!res.ok) return jsonResponse({ status: "routing_unavailable", message: `Routing service returned ${res.status}` }, 502);
    const route = parseRouteResponse(await res.json());

    const { data: saved, error: saveErr } = await serviceRoleClient().rpc("save_route_geometry", {
      p_route_id: route_id,
      p_stops_hash: inputs.stops_hash,
      p_polyline6: route.polyline6,
      p_distance_m: route.distanceM,
      p_duration_s: route.durationS,
    });
    if (saveErr) return jsonResponse({ error: saveErr.message }, 500);
    if (!saved?.saved) return jsonResponse({ status: "not_saved", reason: saved?.reason }, 409);
    return jsonResponse({ status: "built", route_id, distance_m: route.distanceM });
  } catch (e) {
    return jsonResponse({ status: "routing_unavailable", message: e instanceof Error ? e.message : "Unexpected error" }, 502);
  }
});
