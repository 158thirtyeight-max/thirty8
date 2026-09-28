"use client";

import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function SignOutButton() {
  const router = useRouter();

  return (
    <button
      onClick={async () => {
        await createClient().auth.signOut();
        router.push("/login");
        router.refresh();
      }}
      className="mt-4 rounded-lg px-3 py-2 text-left text-sm text-text-secondary transition hover:bg-primary/10 hover:text-primary"
    >
      Sign out
    </button>
  );
}
