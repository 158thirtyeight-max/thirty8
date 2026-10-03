import { handleOptions, jsonResponse } from "./cors.ts";
import { blockedBody, providerReadiness } from "./provider.ts";
import { callerClient, serviceRoleClient } from "./supabase.ts";

// Shared body of the provider-payout functions (operator-onboard, process-settlement, reverse-operator-transfer,
// reconcile-transfers). Razorpay Route / RazorpayX are DISABLED in this release: after checking that the caller is a
// full admin, these functions report what is missing and stop. They never call a provider, never create a transfer
// id and never change a settlement. Live payouts are made from the manual SBI bulk file.
export async function handleProviderRequest(req: Request, action: string): Promise<Response> {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const caller = callerClient(req);
  const { data: isFullAdmin, error } = await caller.rpc("am_i_full_admin");
  if (error || !isFullAdmin) return jsonResponse({ error: "Only full platform admins can use this function" }, 403);

  const admin = serviceRoleClient();
  const { data: settings } = await admin.from("platform_settings").select("key, value").in("key", ["settlement_provider", "razorpay_route_enabled"]);
  const setting = (k: string) => (settings ?? []).find((s: { key: string }) => s.key === k)?.value;
  const has = async (key: string) => !!(await admin.rpc("get_app_secret", { p_key: key })).data;
  const [hasKeyId, hasKeySecret, hasRazorpayxAccount] = await Promise.all([
    has("razorpay_key_id"), has("razorpay_key_secret"), has("razorpayx_account_number"),
  ]);
  const { count } = await admin.from("operator_payment_profiles").select("operator_id", { count: "exact", head: true }).not("razorpay_account_id", "is", null);

  const readiness = providerReadiness({
    provider: String(setting("settlement_provider") ?? "manual_sbi"),
    routeEnabled: setting("razorpay_route_enabled") === true,
    hasKeyId, hasKeySecret, hasRazorpayxAccount,
    operatorsOnboarded: (count ?? 0) > 0,
  });
  if (String(setting("settlement_provider") ?? "manual_sbi") === "manual_sbi") {
    return jsonResponse({ ok: false, code: "blocked_provider_not_configured", action, message: "Settlement is paid by the manual SBI bulk file; automated payouts are not in use.", blockers: [] }, 409);
  }
  return jsonResponse(blockedBody(action, readiness), 409);
}
