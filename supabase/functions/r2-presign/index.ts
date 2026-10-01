import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callerClient, serviceRoleClient } from "../_shared/supabase.ts";
import { getR2Config, presignPut } from "../_shared/r2.ts";

// Issues a short-lived presigned R2 upload URL for one bus photograph. The
// caller must be staff of the bus's operator (or a platform admin); the object
// key is generated here, never taken from the client. The app uploads the file
// straight to R2 with a PUT, then stores the returned `key` on the bus row.
const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { bus_id, side, content_type } = await req.json();
    if (typeof bus_id !== "string" || !["exterior", "interior"].includes(side) || !EXT[content_type]) {
      return jsonResponse({ error: "bus_id, side (exterior|interior) and content_type (jpeg|png|webp) are required" }, 400);
    }

    const { data: userData, error: userErr } = await callerClient(req).auth.getUser();
    if (userErr || !userData.user) return jsonResponse({ error: "Not signed in" }, 401);
    const userId = userData.user.id;

    const admin = serviceRoleClient();
    const { data: bus } = await admin.from("buses").select("id, operator_id").eq("id", bus_id).maybeSingle();
    if (!bus) return jsonResponse({ error: "Bus not found" }, 404);

    const { data: roles } = await admin.from("user_roles").select("role, operator_id").eq("user_id", userId);
    const allowed = (roles ?? []).some((r) =>
      ["platform_admin", "platform_support"].includes(r.role) ||
      (r.operator_id === bus.operator_id && ["operator_admin", "operator_staff"].includes(r.role))
    );
    if (!allowed) return jsonResponse({ error: "Not allowed to upload photos for this bus" }, 403);

    const cfg = await getR2Config();
    const key = `bus-photos/${bus.operator_id}/${bus.id}/${side}_${crypto.randomUUID()}.${EXT[content_type]}`;
    const uploadUrl = await presignPut(cfg, key, content_type);
    return jsonResponse({ upload_url: uploadUrl, key, public_url: `${cfg.publicBaseUrl}/${key}` });
  } catch (e) {
    console.error("r2-presign failed", e);
    return jsonResponse({ error: "Could not prepare the upload" }, 500);
  }
});
