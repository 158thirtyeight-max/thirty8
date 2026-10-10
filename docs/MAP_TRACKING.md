# Trip map & live bus tracking

Road-following route + stops + live bus position, shown in the customer app (booking detail → trip map)
and the operator app (Trip details → Tracking). No Google services.

| Piece | Technology | Key needed |
|---|---|---|
| Map rendering | `maplibre_gl` (shared package `packages/route_map`) | none |
| Base map | OpenFreeMap `liberty` style (OpenStreetMap data) | none |
| Road routing | OSRM `/route` call from the `route-geometry` Edge Function | none (public demo) / your own server |
| Live position | existing Supabase tracking system | – |

Attribution (© OpenStreetMap contributors · OpenFreeMap) is shown under every map.

## Configuration

* **`MAP_STYLE_URL`** (`--dart-define`, optional): a self-hosted MapLibre style instead of OpenFreeMap.
* **`OSRM_BASE_URL`** (Edge Function secret, optional): `supabase secrets set OSRM_BASE_URL=https://osrm.example.com`.
  Default is the public demo `router.project-osrm.org`, which is for light testing only
  (no uptime or rate guarantee). For production run your own OSRM with the India/Andaman extract.
  Routes are computed once per route change, so volume is tiny, but the dependency should still be yours.
* Deploy: `supabase functions deploy route-geometry` (JWT verification stays **on**).
* Android: `INTERNET` added to both apps; the operator app also declares `ACCESS_FINE/COARSE_LOCATION`.
  iOS: operator `Info.plist` has `NSLocationWhenInUseUsageDescription`.

## Database (migration `20261008000100_route_map_geometry.sql`)

Reuses `bus_routes` (one row per direction, so a trip's `route_id` already *is* its direction),
`boarding_points` / `dropping_points`, `locations`, `bus_trips`, `booking_items`, and the existing tracking
tables. **One new table**: `route_geometries(route_id, stops_hash, polyline6, distance_m, duration_s, provider, computed_at)`.

| Function | Who | Purpose |
|---|---|---|
| `get_trip_route_map(trip)` | operator staff / admin / customer with a confirmed booking | ordered stops, direction, customer's own pickup & drop, stored geometry + `is_current` |
| `get_route_geometry_inputs(route)` | operator staff of that route / admin | waypoints + hash for the Edge Function |
| `save_route_geometry(...)` | **service role only** | stores geometry; refuses it if the stops changed meanwhile |
| `get_trip_tracking(trip)` (extended) | same audience as the map | now also `speed_kmh`, `heading`, `accuracy_m` of the fix used |
| `update_bus_location(...)` (extended) | operator staff of the trip | adds speed/heading; ignored unless the bus has driver fallback enabled; max one fix / 5 s |

RLS: `route_geometries` has RLS on and **no** client grants — it is only reachable through the functions above.
`vehicle_location_observations` is still unreadable to every client.

## Route generation

1. Operator opens a trip's Tracking section; if `get_trip_route_map` says the geometry is missing or not current
   (`is_current = false`), the app calls the `route-geometry` Edge Function once.
2. The function (caller's JWT → `get_route_geometry_inputs`, staff check) compares the stops hash. **Unchanged → returns `cached`, OSRM is not called.**
3. Otherwise it asks OSRM for a driving route through the ordered stops (`overview=full&geometries=polyline6`), and stores it
   via `save_route_geometry`.
4. Customers only ever *read* the stored geometry. Stale geometry (stops edited later) is never drawn as the route;
   the map shows stops only until it is rebuilt. A straight line between stops is never drawn.

Changing a stop coordinate changes the hash, so the next staff view rebuilds it automatically.

## Live location

```
tracker (gps-ingest)  ─┐
driver phone (opt-in) ─┴→ vehicle_location_observations → private.compute_tracking (tracker first)
                                 → refresh_trip_location → realtime.send('trip:<id>:track') (ping, no coordinates)
Customer / operator map: subscribes to that ONE private channel → re-reads get_trip_tracking
                         (+ 30 s safety poll; stops both when the trip has ended)
```

* Tracker-first / `allow_driver_fallback` policy is unchanged. The phone is only accepted for buses an admin enabled.
* Driver phone: a per-trip switch ("Share this phone's location") visible only while the trip is boarding/departed.
  Fixes are sent when the bus moved ≥ 25 m and ≥ 10 s passed, or as a 60 s heartbeat; GPS stream distance filter 10 m.
* "Live" is shown only when the fix is ≤ 120 s old **measured on the server clock**; it then decays to
  "Last updated N min ago", and after 15 min to "Live tracking temporarily unavailable". Estimates are labelled.
* Heading is used only when the source reports one (otherwise a plain marker without pointer). The marker glides
  between real fixes (≤ 1.5 km apart); larger jumps are shown as they are.

## Known limitations

* Driver-phone sharing is foreground only (screen must stay on); no background service.
* OpenFreeMap / OSRM public instances have no SLA (see above).
* Stop-name labels use the style's `Noto Sans Regular` font stack; a custom style must provide it.
* The rendering itself (MapLibre native view) is not covered by automated tests, only the data/logic around it.
