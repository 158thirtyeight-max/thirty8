// OSRM road-route helpers (pure: no I/O), so they can be unit tested without a network.

export interface Waypoint {
  latitude: number;
  longitude: number;
}

export interface RoadRoute {
  polyline6: string;
  distanceM: number;
  durationS: number;
}

// OSRM takes lng,lat pairs; the geometry comes back as an encoded polyline with 6 decimals.
export function buildRouteUrl(baseUrl: string, waypoints: Waypoint[]): string {
  if (waypoints.length < 2) throw new Error("A route needs at least two stops with coordinates");
  const coords = waypoints.map((w) => `${w.longitude.toFixed(6)},${w.latitude.toFixed(6)}`).join(";");
  const base = baseUrl.replace(/\/+$/, "");
  return `${base}/route/v1/driving/${coords}?overview=full&geometries=polyline6&steps=false&continue_straight=false`;
}

// Accepts only a real road route. Anything else (NoRoute, empty geometry) is an error, never a
// straight line between the stops.
export function parseRouteResponse(body: unknown): RoadRoute {
  const b = body as { code?: string; message?: string; routes?: Array<{ geometry?: unknown; distance?: unknown; duration?: unknown }> };
  if (!b || b.code !== "Ok") {
    throw new Error(`Routing service could not find a road route (${b?.code ?? "no response"}${b?.message ? `: ${b.message}` : ""})`);
  }
  const r = b.routes?.[0];
  if (!r || typeof r.geometry !== "string" || r.geometry.length < 4) throw new Error("Routing service returned no geometry");
  return { polyline6: r.geometry, distanceM: Number(r.distance ?? 0), durationS: Number(r.duration ?? 0) };
}
