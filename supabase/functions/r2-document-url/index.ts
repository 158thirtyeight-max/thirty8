import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callerClient } from "../_shared/supabase.ts";
import { getR2DocumentConfig, presignGet } from "../_shared/r2.ts";

// Returns a 10-minute presigned GET URL for one bus document stored in R2.
// RLS on bus_documents (read through the caller's own client) decides access:
// only staff of the bus's operator and platform admins can see the row.
Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { doc_id } = await req.json();
    if (typeof doc_id !== "string") return jsonResponse({ error: "doc_id is required" }, 400);

    const caller = callerClient(req);
    const { data: userData, error: userErr } = await caller.auth.getUser();
    if (userErr || !userData.user) return jsonResponse({ error: "Not signed in" }, 401);

    const { data: doc } = await caller.from("bus_documents").select("bucket, file_path").eq("id", doc_id).maybeSingle();
    if (!doc) return jsonResponse({ error: "Document not found" }, 404);
    if (doc.bucket !== "r2") return jsonResponse({ error: "Document is not stored in R2" }, 400);

    const url = await presignGet(await getR2DocumentConfig(), doc.file_path);
    return jsonResponse({ url });
  } catch (e) {
    console.error("r2-document-url failed", e);
    return jsonResponse({ error: "Could not open the document" }, 500);
  }
});
