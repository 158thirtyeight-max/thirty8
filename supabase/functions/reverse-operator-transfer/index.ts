import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleProviderRequest } from "../_shared/provider_handler.ts";

// Provider payout module (disabled): answers "blocked" and never moves money. See _shared/provider_handler.ts.
Deno.serve((req) => handleProviderRequest(req, "reverse-operator-transfer"));
