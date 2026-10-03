// Settlement payout providers. The ONLY live payout method is the manual SBI bulk file (no API).
// Razorpay Route / RazorpayX are modelled here so they can be switched on later, but they are DISABLED:
// `providerReadiness` lists exactly what is still missing, the database refuses to enable them
// (admin_set_platform_setting), and the edge functions that would use them answer "blocked" and never
// call a provider, never invent a transfer id and never mark anything paid.
// Pure functions (no Deno APIs): unit-tested under Node in supabase/tests/edge/provider.test.mjs.

export type ProviderKind = "manual_sbi" | "razorpay_route" | "razorpayx";

export type ProviderConfig = {
  provider: string;
  routeEnabled: boolean;
  hasKeyId: boolean;
  hasKeySecret: boolean;
  hasRazorpayxAccount: boolean; // RazorpayX business account number secret
  operatorsOnboarded: boolean; // at least one operator has a provider account configured and verified
};

export type Readiness = { ready: boolean; blockers: string[] };

export function providerReadiness(cfg: ProviderConfig): Readiness {
  const blockers: string[] = [];
  switch (cfg.provider) {
    case "manual_sbi":
      return { ready: true, blockers };
    case "razorpay_route":
      if (!cfg.routeEnabled) blockers.push("razorpay_route_enabled is false (needs Razorpay Route approval on the account)");
      if (!cfg.hasKeyId || !cfg.hasKeySecret) blockers.push("Razorpay API keys are not configured");
      if (!cfg.operatorsOnboarded) blockers.push("no operator has a verified Razorpay linked account");
      break;
    case "razorpayx":
      if (!cfg.hasKeyId || !cfg.hasKeySecret) blockers.push("Razorpay API keys are not configured");
      if (!cfg.hasRazorpayxAccount) blockers.push("RazorpayX account number is not configured");
      if (!cfg.operatorsOnboarded) blockers.push("no operator has a verified payout contact / fund account");
      break;
    default:
      blockers.push(`unknown provider "${cfg.provider}"`);
  }
  // even with everything configured, the provider integration itself is not built or approved yet
  blockers.push("provider payout integration is not enabled in this release (manual SBI settlement is in use)");
  return { ready: false, blockers };
}

export function blockedBody(action: string, readiness: Readiness) {
  return {
    ok: false,
    code: "blocked_provider_not_configured",
    action,
    message: "Automated provider payouts are disabled. Settlements are paid by the manual SBI bulk file.",
    blockers: readiness.blockers,
  };
}
