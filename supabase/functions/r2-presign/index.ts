import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callerClient, serviceRoleClient } from "../_shared/supabase.ts";
import { getR2Config, getR2DocumentConfig, presignPut } from "../_shared/r2.ts";

// Issues a short-lived presigned R2 upload URL for one bus photograph, or (when
// `doc_type` is sent instead of `side`) for one private bus document. The
// caller must be staff of the bus's operator (or a platform admin); the object
// key is generated here, never taken from the client. The app uploads the file
// straight to R2 with a PUT, then stores the returned `key` on the bus row.
const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };
const DOC_EXT: Record<string, string> = { "application/pdf": "pdf", "image/webp": "webp" };

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { bus_id, side, content_type, doc_type } = await req.json();
    const isDoc = typeof doc_type === "string";
    if (typeof bus_id !== "string") return jsonResponse({ error: "bus_id is required" }, 400);
    if (isDoc) {
      if (!/^[a-z_]{2,30}$/.test(doc_type) || !DOC_EXT[content_type]) {
        return jsonResponse({ error: "doc_type and content_type (pdf|jpeg|png) are required" }, 400);
      }
    } else if (!["exterior", "interior"].includes(side) || !EXT[content_type]) {
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
    if (!allowed) return jsonResponse({ error: "Not allowed to upload files for this bus" }, 403);

    if (isDoc) {
      const { data: req_ } = await admin.from("document_requirements").select("doc_type").eq("scope", "bus").eq("doc_type", doc_type).maybeSingle();
      if (!req_) return jsonResponse({ error: "Unknown document type" }, 400);
      const docCfg = await getR2DocumentConfig();
      const docKey = `bus-documents/${bus.operator_id}/${bus.id}/${doc_type}_${crypto.randomUUID()}.${DOC_EXT[content_type]}`;
      return jsonResponse({ upload_url: await presignPut(docCfg, docKey, content_type), key: docKey });
    }

    const cfg = await getR2Config();
    const key = `bus-photos/${bus.operator_id}/${bus.id}/${side}_${crypto.randomUUID()}.${EXT[content_type]}`;
    const uploadUrl = await presignPut(cfg, key, content_type);
    return jsonResponse({ upload_url: uploadUrl, key, public_url: `${cfg.publicBaseUrl}/${key}` });
  } catch (e) {
    console.error("r2-presign failed", e);
    return jsonResponse({ error: "Could not prepare the upload" }, 500);
  }
});
