import { createClient } from "jsr:@supabase/supabase-js@2";

// Full-privilege client: bypasses RLS, used for reading secrets and for the
// payment-fulfillment RPCs (confirm_booking_after_payment / handle_payment_failure
// / confirm_refund) that are deliberately locked to service_role only.
export function serviceRoleClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}

// Caller-scoped client: forwards the request's own Authorization header, so
// RLS applies exactly as it would for a direct client call (e.g. reading
// only the caller's own order).
export function callerClient(req: Request) {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
}

export async function getRazorpayCredentials() {
  const admin = serviceRoleClient();
  const [{ data: keyId }, { data: keySecret }] = await Promise.all([
    admin.rpc("get_app_secret", { p_key: "razorpay_key_id" }),
    admin.rpc("get_app_secret", { p_key: "razorpay_key_secret" }),
  ]);
  if (!keyId || !keySecret) {
    throw new Error("Razorpay is not configured (missing razorpay_key_id/razorpay_key_secret in private.app_secrets)");
  }
  return { keyId: keyId as string, keySecret: keySecret as string };
}

export function razorpayAuthHeader(keyId: string, keySecret: string) {
  return "Basic " + btoa(`${keyId}:${keySecret}`);
}
