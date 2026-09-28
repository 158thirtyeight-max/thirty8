"use client";

import { useState, useTransition } from "react";

export default function ProcessButton({ refundId, action }: { refundId: string; action: (id: string) => Promise<void> }) {
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  return (
    <div>
      <button
        disabled={isPending}
        onClick={() =>
          startTransition(async () => {
            setError(null);
            try {
              await action(refundId);
            } catch (e) {
              setError(e instanceof Error ? e.message : "Failed to process refund");
            }
          })
        }
        className="rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-white hover:bg-primary-dark disabled:opacity-50"
      >
        {isPending ? "Processing…" : "Process refund"}
      </button>
      {error && <p className="mt-1 max-w-xs text-xs text-error">{error}</p>}
    </div>
  );
}
