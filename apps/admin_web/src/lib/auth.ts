import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

/**
 * Gate for every page under app/(admin). Calls the same
 * public.am_i_platform_admin() RPC the mobile apps use — a customer or
 * operator account that somehow reaches this app gets bounced to /login
 * with a clear message instead of an empty/broken dashboard.
 */
export async function requirePlatformAdmin() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: isAdmin, error } = await supabase.rpc("am_i_platform_admin");

  if (error || !isAdmin) redirect("/login?error=not_authorized");

  return { supabase, user };
}
