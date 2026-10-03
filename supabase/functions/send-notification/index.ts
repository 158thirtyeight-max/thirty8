import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { jsonResponse } from "../_shared/cors.ts";
import { serviceRoleClient } from "../_shared/supabase.ts";
import { sendFcmPush } from "../_shared/fcm.ts";

// Internal-only endpoint (verify_jwt=false; authenticated instead via a
// shared secret header). Called by the booking_status_history /
// cargo_status_history dispatch triggers (via pg_net) — never by end-user
// clients directly. Always records the in-app notification row; push
// delivery is best-effort and silently skipped if FCM isn't configured yet
// or the user has push disabled / no registered device.
function renderTemplate(template: string, data: Record<string, unknown>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_, key) => String(data[key] ?? ""));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const admin = serviceRoleClient();

  const { data: expectedSecret } = await admin.rpc("get_app_secret", { p_key: "internal_dispatch_secret" });
  const providedSecret = req.headers.get("x-internal-secret");
  if (!expectedSecret || providedSecret !== expectedSecret) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    const { profile_id, template_key, data, push_only } = await req.json();
    if (!profile_id || !template_key) {
      return jsonResponse({ error: "profile_id and template_key are required" }, 400);
    }

    const { data: template } = await admin
      .from("notification_templates")
      .select("title_template, body_template")
      .eq("key", template_key)
      .single();

    if (!template) {
      return jsonResponse({ error: `Unknown template_key: ${template_key}` }, 400);
    }

    const title = renderTemplate(template.title_template, data ?? {});
    const body = renderTemplate(template.body_template, data ?? {});

    // push_only: the in-app row was already written (and de-duplicated per event) by the database
    // (private.notify, used by the financial notifications); only deliver the push here.
    if (!push_only) {
      await admin.from("notifications").insert({
        profile_id,
        title,
        body,
        type: template_key,
        data: data ?? {},
      });
    }

    const { data: prefs } = await admin
      .from("notification_preferences")
      .select("push_enabled")
      .eq("profile_id", profile_id)
      .maybeSingle();

    if (prefs && prefs.push_enabled === false) {
      return jsonResponse({ ok: true, push_sent: false, reason: "push disabled by user" });
    }

    const { data: serviceAccountJson } = await admin.rpc("get_app_secret", { p_key: "fcm_service_account_json" });
    if (!serviceAccountJson) {
      return jsonResponse({ ok: true, push_sent: false, reason: "FCM not configured" });
    }

    const { data: tokens } = await admin
      .from("device_tokens")
      .select("fcm_token")
      .eq("profile_id", profile_id);

    if (!tokens || tokens.length === 0) {
      return jsonResponse({ ok: true, push_sent: false, reason: "no registered devices" });
    }

    const results = await Promise.all(
      tokens.map((t) =>
        sendFcmPush(serviceAccountJson as string, t.fcm_token, title, body, { type: template_key })
      ),
    );

    return jsonResponse({ ok: true, push_sent: true, results });
  } catch (err) {
    console.error(err);
    return jsonResponse({ error: "Unexpected error" }, 500);
  }
});
