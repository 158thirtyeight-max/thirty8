import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { jsonResponse } from "../_shared/cors.ts";
import { serviceRoleClient } from "../_shared/supabase.ts";
import { ADAPTERS } from "./adapters.ts";

// Provider-neutral GPS ingest. A tracker (or its provider's server) calls
//   POST /functions/v1/gps-ingest?provider=<name>
// with the provider's own payload, authenticated by that provider's shared secret
// (stored server-side in private.app_secrets under the device's provider_config_ref —
// never in the apps). The matching adapter in ./adapters.ts turns the payload into
// normalized fixes, which go through the ingest_tracker_location RPC (service role).
//
// NO PROVIDER IS IMPLEMENTED YET: ADAPTERS is empty, so every request is answered with
// 501 and nothing is recorded. A device therefore never appears "connected" unless a real
// adapter delivered a real fix. Adding a provider = one adapter entry + its secret.
//
// verify_jwt = false for this function (trackers do not have Supabase JWTs); authentication
// is the adapter's `authenticate` check, which must run before any parsing.
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const provider = new URL(req.url).searchParams.get("provider") ?? "";
  const adapter = ADAPTERS[provider];
  if (!adapter) {
    return jsonResponse({ error: "no_provider_configured", provider }, 501);
  }

  const admin = serviceRoleClient();
  const { data: secret } = await admin.rpc("get_app_secret", { p_key: adapter.secretKey });
  if (!secret || !(await adapter.authenticate(req.clone(), secret as string))) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let fixes;
  try {
    fixes = await adapter.parse(req);
  } catch (_e) {
    return jsonResponse({ error: "bad_payload" }, 400);
  }

  const results = [];
  for (const f of fixes) {
    const { data, error } = await admin.rpc("ingest_tracker_location", {
      p_provider: provider,
      p_device_identifier: f.deviceIdentifier,
      p_latitude: f.latitude,
      p_longitude: f.longitude,
      p_recorded_at: f.recordedAt,
      p_accuracy_m: f.accuracyM ?? null,
      p_speed_kmh: f.speedKmh ?? null,
      p_heading: f.heading ?? null,
    });
    results.push(error ? { accepted: false, reason: "rpc_error" } : data);
  }
  return jsonResponse({ results });
});
